//! Speech to text: whisper-cli on this PC, or the Groq or OpenAI API.

use crate::http::{self, Multipart};
use crate::{CancelFlag, Error};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

pub trait Transcriber: Send + Sync {
    fn name(&self) -> &str;
    fn transcribe(&self, wav: &[u8], cancel: &CancelFlag) -> Result<String, Error>;
}

/// Windows would flash a console window for every run without this.
pub(crate) fn hide_console(command: &mut Command) -> &mut Command {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
}

/// Where speech sits while whisper-cli reads it. Only the fallback path writes
/// here: whisper-server gets the audio straight from memory.
pub fn temporary_audio_folder() -> PathBuf {
    std::env::temp_dir().join("holdtalk")
}

/// Removes anything left behind by a crash.
pub fn remove_leftover_audio() {
    let _ = std::fs::remove_dir_all(temporary_audio_folder());
}

/// Runs whisper-cli as a separate process, so Esc can kill it outright.
pub struct WhisperCli {
    pub executable: PathBuf,
    pub model: PathBuf,
    pub language: String,
}

impl Transcriber for WhisperCli {
    fn name(&self) -> &str {
        "whisper.cpp"
    }

    fn transcribe(&self, wav: &[u8], cancel: &CancelFlag) -> Result<String, Error> {
        let folder = temporary_audio_folder();
        std::fs::create_dir_all(&folder).map_err(|_| Error::failed("Couldn't write temporary audio."))?;
        let id = format!(
            "{:x}",
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)
        );
        let audio = TemporaryFile(folder.join(format!("{id}.wav")));
        let output_base = folder.join(format!("{id}-out"));
        let output = TemporaryFile(output_base.with_extension("txt"));
        std::fs::write(&audio.0, wav).map_err(|_| Error::failed("Couldn't write temporary audio."))?;

        let mut command = Command::new(&self.executable);
        command
            .arg("-m")
            .arg(&self.model)
            .arg("-f")
            .arg(&audio.0)
            .args(["-l", &self.language, "-nt", "-np", "-otxt", "-of"])
            .arg(&output_base)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut child = hide_console(&mut command)
            .spawn()
            .map_err(|e| Error::failed(format!("Couldn't start whisper-cli: {e}")))?;
        let status = loop {
            if cancel.is_cancelled() {
                let _ = child.kill();
                let _ = child.wait();
                return Err(Error::Cancelled);
            }
            match child.try_wait() {
                Ok(Some(status)) => break status,
                Ok(None) => std::thread::sleep(Duration::from_millis(15)),
                Err(e) => return Err(Error::failed(format!("whisper-cli failed: {e}"))),
            }
        };
        if !status.success() {
            return Err(Error::failed(format!(
                "whisper-cli stopped with error {}. Check the model file: {}",
                status.code().unwrap_or(-1),
                self.model.display()
            )));
        }
        std::fs::read_to_string(&output.0).map_err(|_| Error::failed("whisper-cli wrote no transcript."))
    }
}

/// Deleted when dropped, so speech never stays on disk after a transcription.
struct TemporaryFile(PathBuf);

impl Drop for TemporaryFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// Groq and OpenAI share this upload format.
pub struct WhisperApi {
    pub name: String,
    pub endpoint: String,
    pub api_key: String,
    pub model: String,
    pub language: String,
}

impl Transcriber for WhisperApi {
    fn name(&self) -> &str {
        &self.name
    }

    fn transcribe(&self, wav: &[u8], cancel: &CancelFlag) -> Result<String, Error> {
        let mut form = Multipart::new();
        form.field("model", &self.model);
        form.field("response_format", "json");
        if self.language != "auto" {
            form.field("language", &self.language);
        }
        form.wav(wav);
        let (content_type, body) = form.finish();
        let authorization = format!("Bearer {}", self.api_key);
        let reply = http::post(
            Duration::from_secs(60),
            &self.endpoint,
            &[("Authorization", &authorization)],
            &content_type,
            &body,
            &self.name,
        )?;
        cancel.check()?;
        http::text_field(&reply, &self.name)
    }
}

/// Removes Whisper's non-speech markers such as [BLANK_AUDIO] and joins its lines.
pub fn tidy_transcript(text: &str) -> String {
    use std::sync::OnceLock;
    static BRACKETS: OnceLock<regex::Regex> = OnceLock::new();
    static SOUND_LINES: OnceLock<regex::Regex> = OnceLock::new();
    let brackets = BRACKETS.get_or_init(|| regex::Regex::new(r"\[[^\]]*\]").unwrap());
    let sound_lines = SOUND_LINES.get_or_init(|| regex::Regex::new(r"(?m)^\s*\([^)]*\)\s*$").unwrap());
    let without_markers = brackets.replace_all(text, " ");
    let without_markers = sound_lines.replace_all(&without_markers, " ");
    without_markers.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::mock;

    #[test]
    fn tidy() {
        assert_eq!(tidy_transcript(" Hello there.\n And more. \n"), "Hello there. And more.");
        assert_eq!(tidy_transcript("[BLANK_AUDIO]"), "");
        assert_eq!(tidy_transcript("(wind blowing)\n"), "");
        assert_eq!(tidy_transcript("keep (these words) here"), "keep (these words) here");
    }

    #[test]
    fn whisper_api_request() {
        let (url, seen) = mock::serve(200, r#"{"text": "hello world"}"#);
        let api = WhisperApi {
            name: "Groq".into(),
            endpoint: format!("{url}/v1/audio/transcriptions"),
            api_key: "secret".into(),
            model: "m1".into(),
            language: "en".into(),
        };
        let wav = crate::audio::SpeechAudio::new(vec![0.1; 100]).wav_data();
        assert_eq!(api.transcribe(&wav, &CancelFlag::new()).unwrap(), "hello world");
        let seen = seen.recv().unwrap();
        assert_eq!(seen.header("Authorization").as_deref(), Some("Bearer secret"));
        let body = seen.body_text();
        assert!(body.contains("name=\"model\"\r\n\r\nm1"));
        assert!(body.contains("name=\"language\"\r\n\r\nen"));
        assert!(body.contains("filename=\"speech.wav\""));
        assert!(body.contains("RIFF"));
    }

    #[test]
    fn api_error_never_exposes_key() {
        let (url, seen) = mock::serve(401, r#"{"error": "bad key secret"}"#);
        let api = WhisperApi {
            name: "Groq".into(),
            endpoint: url,
            api_key: "secret".into(),
            model: "m".into(),
            language: "auto".into(),
        };
        let error = api.transcribe(b"RIFF", &CancelFlag::new()).unwrap_err();
        assert_eq!(error.to_string(), "Groq returned error 401.");
        assert!(!seen.recv().unwrap().body_text().contains("language"), "auto sends no language");
    }
}
