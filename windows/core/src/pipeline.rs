//! Turns recorded audio into the final text: transcribe, then clean up.

use crate::cleanup::{self, AnthropicCleaner, ChatCompletionsCleaner, Cleaner};
use crate::config::{executable, Config, EnvFile, Paths};
use crate::server::{ServerHost, WhisperServerTranscriber};
use crate::transcribe::{tidy_transcript, Transcriber, WhisperApi, WhisperCli};
use crate::{CancelFlag, Error};
use std::path::Path;
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outcome {
    pub text: String,
    /// Something the user should know, e.g. the cleanup step failed.
    pub notice: Option<String>,
}

pub struct Pipeline {
    /// Tried in order. Local is only ever a fallback for the cloud, never the
    /// reverse, so choosing local guarantees audio stays on this PC.
    pub transcribers: Vec<Box<dyn Transcriber>>,
    pub cleaner: Option<Box<dyn Cleaner>>,
    /// Set when a config choice couldn't be honored, e.g. no API key.
    pub setup_notice: Option<String>,
}

impl Pipeline {
    /// Returns empty text when no speech was found.
    pub fn run(&self, wav: &[u8], cancel: &CancelFlag) -> Result<Outcome, Error> {
        let mut notice = self.setup_notice.clone();
        let raw = tidy_transcript(&self.transcribe(wav, cancel, &mut notice)?);
        cancel.check()?;
        if raw.is_empty() {
            return Ok(Outcome { text: String::new(), notice });
        }
        let Some(cleaner) = &self.cleaner else { return Ok(Outcome { text: raw, notice }) };
        match cleaner.clean(&raw) {
            Ok(output) => {
                cancel.check()?;
                match cleanup::accept(&output, &raw) {
                    Some(accepted) => Ok(Outcome { text: accepted, notice }),
                    None => Ok(Outcome { text: raw, notice: Some("Cleanup reply looked wrong, used the raw text".into()) }),
                }
            }
            Err(_) => {
                cancel.check()?;
                // Being offline must never lose what was said.
                Ok(Outcome { text: raw, notice: Some("Cleanup unavailable, used the raw text".into()) })
            }
        }
    }

    fn transcribe(&self, wav: &[u8], cancel: &CancelFlag, notice: &mut Option<String>) -> Result<String, Error> {
        if self.transcribers.is_empty() {
            return Err(Error::failed(notice.clone().unwrap_or_else(|| "No transcriber is available.".into())));
        }
        let mut last_error = None;
        for transcriber in &self.transcribers {
            cancel.check()?;
            if last_error.is_some() {
                *notice = Some(format!("{} failed, used {}", self.transcribers[0].name(), transcriber.name()));
            }
            match transcriber.transcribe(wav, cancel) {
                Ok(text) => return Ok(text),
                Err(Error::Cancelled) => return Err(Error::Cancelled),
                Err(error) => last_error = Some(error),
            }
        }
        Err(last_error.unwrap_or_else(|| Error::failed("Transcription failed.")))
    }

    /// Builds the pipeline the settings and .env ask for. `whisper_folder` is
    /// where the installer put whisper-server.exe and whisper-cli.exe.
    pub fn make(config: &Config, env: &EnvFile, paths: &Paths, whisper_folder: Option<&Path>, servers: &ServerHost) -> Pipeline {
        let mut transcribers: Vec<Box<dyn Transcriber>> = Vec::new();
        let mut notices: Vec<String> = Vec::new();

        let mut cloud = |name: &str, url: &str, key_name: &str, default_model: &str| match env.get(key_name) {
            Some(key) => transcribers.push(Box::new(WhisperApi {
                name: name.into(),
                endpoint: url.into(),
                api_key: key.into(),
                model: config.transcriber_model.clone().unwrap_or_else(|| default_model.into()),
                language: config.language.clone(),
            })),
            None => notices.push(format!("No {key_name} in .env, used local Whisper")),
        };
        match config.transcriber.as_str() {
            "groq" => cloud(
                "Groq",
                "https://api.groq.com/openai/v1/audio/transcriptions",
                "GROQ_API_KEY",
                "whisper-large-v3-turbo",
            ),
            "openai" => cloud("OpenAI", "https://api.openai.com/v1/audio/transcriptions", "OPENAI_API_KEY", "gpt-transcribe"),
            _ => {}
        }

        let model = config.model_path(paths);
        match config.whisper_cli(whisper_folder) {
            Some(cli) if model.is_file() => {
                let fallback = Box::new(WhisperCli { executable: cli.clone(), model: model.clone(), language: config.language.clone() });
                let server_exe = cli.with_file_name(executable("whisper-server"));
                if server_exe.is_file() {
                    transcribers.push(Box::new(WhisperServerTranscriber {
                        server: servers.server(&server_exe, &model),
                        language: config.language.clone(),
                        fallback,
                    }));
                } else {
                    transcribers.push(fallback);
                }
            }
            cli => {
                if transcribers.is_empty() {
                    notices = vec![if cli.is_none() {
                        "whisper-cli is missing. Reinstall HoldTalk, or fix whisperPath in the settings.".into()
                    } else {
                        "Speech model missing. Use \"Download speech model\" in the tray menu.".into()
                    }];
                }
            }
        }

        Pipeline { transcribers, cleaner: make_cleaner(config, env), setup_notice: notices.into_iter().next() }
    }
}

pub fn make_cleaner(config: &Config, env: &EnvFile) -> Option<Box<dyn Cleaner>> {
    if !config.cleanup_enabled {
        return None;
    }
    let order: Vec<&str> = if config.cleanup_provider == "auto" {
        vec!["groq", "anthropic", "openai"]
    } else {
        vec![config.cleanup_provider.as_str()]
    };
    let timeout = Duration::from_secs_f64(config.cleanup_timeout_seconds);
    let model = |default: &str| config.cleanup_model.clone().unwrap_or_else(|| default.into());
    for provider in order {
        match provider {
            "groq" => {
                if let Some(key) = env.get("GROQ_API_KEY") {
                    return Some(Box::new(ChatCompletionsCleaner {
                        endpoint: "https://api.groq.com/openai/v1/chat/completions".into(),
                        api_key: key.into(),
                        model: model("llama-3.3-70b-versatile"),
                        casing: config.casing.clone(),
                        timeout,
                    }));
                }
            }
            "anthropic" => {
                if let Some(key) = env.get("ANTHROPIC_API_KEY") {
                    return Some(Box::new(AnthropicCleaner {
                        endpoint: "https://api.anthropic.com/v1/messages".into(),
                        api_key: key.into(),
                        model: model("claude-haiku-5-5"),
                        casing: config.casing.clone(),
                        timeout,
                    }));
                }
            }
            _ => {
                if let Some(key) = env.get("OPENAI_API_KEY") {
                    return Some(Box::new(ChatCompletionsCleaner {
                        endpoint: "https://api.openai.com/v1/chat/completions".into(),
                        api_key: key.into(),
                        model: model("gpt-5.6-luna"),
                        casing: config.casing.clone(),
                        timeout,
                    }));
                }
            }
        }
    }
    None
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::path::PathBuf;

    pub(crate) struct FakeTranscriber {
        pub name: &'static str,
        pub result: Result<String, Error>,
    }

    impl Transcriber for FakeTranscriber {
        fn name(&self) -> &str {
            self.name
        }
        fn transcribe(&self, _: &[u8], _: &CancelFlag) -> Result<String, Error> {
            self.result.clone()
        }
    }

    pub(crate) struct FakeCleaner(pub Result<String, Error>);

    impl Cleaner for FakeCleaner {
        fn clean(&self, _: &str) -> Result<String, Error> {
            self.0.clone()
        }
    }

    pub(crate) fn fixed(text: &str) -> Box<dyn Transcriber> {
        Box::new(FakeTranscriber { name: "fixed", result: Ok(text.into()) })
    }

    fn pipeline(transcribers: Vec<Box<dyn Transcriber>>, cleaner: Option<Result<String, Error>>) -> Pipeline {
        Pipeline {
            transcribers,
            cleaner: cleaner.map(|r| Box::new(FakeCleaner(r)) as Box<dyn Cleaner>),
            setup_notice: None,
        }
    }

    fn run(p: &Pipeline) -> Result<Outcome, Error> {
        p.run(b"RIFF", &CancelFlag::new())
    }

    #[test]
    fn cleaned_text_is_used() {
        let p = pipeline(vec![fixed("um hello there")], Some(Ok("Hello there.".into())));
        assert_eq!(run(&p).unwrap(), Outcome { text: "Hello there.".into(), notice: None });
    }

    #[test]
    fn offline_cleanup_still_delivers_raw_text() {
        let p = pipeline(vec![fixed("um hello")], Some(Err(Error::failed("offline"))));
        let outcome = run(&p).unwrap();
        assert_eq!(outcome.text, "um hello");
        assert!(outcome.notice.is_some());
    }

    #[test]
    fn no_cleaner_means_raw_text() {
        let p = pipeline(vec![fixed("um hello")], None);
        assert_eq!(run(&p).unwrap(), Outcome { text: "um hello".into(), notice: None });
    }

    #[test]
    fn model_answering_instead_of_editing_is_rejected() {
        let answer = "The capital of France is Paris. ".repeat(10);
        let p = pipeline(vec![fixed("what is the capital of france")], Some(Ok(answer)));
        let outcome = run(&p).unwrap();
        assert_eq!(outcome.text, "what is the capital of france");
        assert!(outcome.notice.is_some());
    }

    #[test]
    fn blank_audio_marker_means_no_speech_and_skips_cleanup() {
        let p = pipeline(vec![fixed("[BLANK_AUDIO]")], Some(Ok("should not be used".into())));
        assert_eq!(run(&p).unwrap().text, "");
    }

    #[test]
    fn cloud_failure_falls_back_to_local() {
        let failing = Box::new(FakeTranscriber { name: "failing", result: Err(Error::failed("down")) });
        let p = pipeline(vec![failing, fixed("hello")], None);
        let outcome = run(&p).unwrap();
        assert_eq!(outcome.text, "hello");
        assert_eq!(outcome.notice.as_deref(), Some("failing failed, used fixed"));
    }

    #[test]
    fn all_transcribers_failing() {
        let failing = Box::new(FakeTranscriber { name: "failing", result: Err(Error::failed("nope")) });
        assert_eq!(run(&pipeline(vec![failing], None)).unwrap_err(), Error::failed("nope"));
    }

    #[test]
    fn cancelled_before_cleanup_returns_nothing() {
        let cancel = CancelFlag::new();
        cancel.cancel();
        let p = pipeline(vec![fixed("hello")], Some(Ok("Hello.".into())));
        assert_eq!(p.run(b"RIFF", &cancel).unwrap_err(), Error::Cancelled);
    }

    fn local_setup() -> (tempfolder::Folder, Paths) {
        let folder = tempfolder::Folder::new();
        let paths = Paths::new(folder.0.clone());
        std::fs::create_dir_all(&paths.models).unwrap();
        std::fs::write(paths.models.join("ggml-small.bin"), b"model").unwrap();
        std::fs::write(folder.0.join(executable("whisper-cli")), b"").unwrap();
        (folder, paths)
    }

    #[test]
    fn local_choice_never_uses_cloud_for_speech() {
        let (folder, paths) = local_setup();
        let env = EnvFile::parse("GROQ_API_KEY=k\nOPENAI_API_KEY=k");
        let p = Pipeline::make(&Config::default(), &env, &paths, Some(&folder.0), &ServerHost::default());
        assert_eq!(p.transcribers.len(), 1);
        assert_eq!(p.transcribers[0].name(), "whisper.cpp");
        assert_eq!(p.setup_notice, None);
    }

    #[test]
    fn server_is_used_when_installed() {
        let (folder, paths) = local_setup();
        std::fs::write(folder.0.join(executable("whisper-server")), b"").unwrap();
        let host = ServerHost::default();
        let p = Pipeline::make(&Config::default(), &EnvFile::default(), &paths, Some(&folder.0), &host);
        assert_eq!(p.transcribers.len(), 1);
        assert!(host.current().is_some(), "The server transcriber was chosen");
    }

    #[test]
    fn cloud_choice_with_key_comes_first_and_missing_key_falls_back() {
        let (folder, paths) = local_setup();
        let config = Config { transcriber: "groq".into(), ..Config::default() };
        let with_key = Pipeline::make(&config, &EnvFile::parse("GROQ_API_KEY=k"), &paths, Some(&folder.0), &ServerHost::default());
        assert_eq!(with_key.transcribers[0].name(), "Groq");
        assert_eq!(with_key.transcribers.len(), 2);
        let no_key = Pipeline::make(&config, &EnvFile::default(), &paths, Some(&folder.0), &ServerHost::default());
        assert_eq!(no_key.transcribers.len(), 1);
        assert_eq!(no_key.setup_notice.as_deref(), Some("No GROQ_API_KEY in .env, used local Whisper"));
    }

    #[test]
    fn missing_model_explains_the_download() {
        let folder = tempfolder::Folder::new();
        std::fs::write(folder.0.join(executable("whisper-cli")), b"").unwrap();
        let paths = Paths::new(folder.0.clone());
        let p = Pipeline::make(&Config::default(), &EnvFile::default(), &paths, Some(&folder.0), &ServerHost::default());
        assert!(p.transcribers.is_empty());
        assert!(p.setup_notice.unwrap().contains("Download speech model"));
    }

    #[test]
    fn cleanup_provider_choice() {
        let mut config = Config::default();
        assert!(make_cleaner(&config, &EnvFile::default()).is_none());
        assert!(make_cleaner(&config, &EnvFile::parse("ANTHROPIC_API_KEY=k")).is_some());
        config.cleanup_provider = "groq".into();
        assert!(make_cleaner(&config, &EnvFile::parse("ANTHROPIC_API_KEY=k")).is_none());
        config.cleanup_enabled = false;
        assert!(make_cleaner(&config, &EnvFile::parse("GROQ_API_KEY=k")).is_none());
    }

    /// A folder under the system temp folder, deleted after the test.
    pub(crate) mod tempfolder {
        use super::PathBuf;
        use std::sync::atomic::{AtomicU32, Ordering};

        pub(crate) struct Folder(pub PathBuf);

        impl Folder {
            pub(crate) fn new() -> Folder {
                static COUNT: AtomicU32 = AtomicU32::new(0);
                let path = std::env::temp_dir()
                    .join(format!("holdtalk-test-{}-{}", std::process::id(), COUNT.fetch_add(1, Ordering::Relaxed)));
                std::fs::create_dir_all(&path).unwrap();
                Folder(path)
            }
        }

        impl Drop for Folder {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
    }
}
