//! Keeps whisper-server running while you dictate, so the model is already loaded
//! when you let go of the hotkey. It stops after a few idle minutes to free the
//! memory. Same flags as the Mac app's `WhisperServer.swift`, so the text matches.

use crate::http::{self, Multipart};
use crate::transcribe::{hide_console, Transcriber};
use crate::{CancelFlag, Error};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

pub struct WhisperServer {
    executable: PathBuf,
    model: PathBuf,
    idle: Duration,
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    child: Option<Child>,
    port: Option<u16>,
    uses: usize,
    last_used: Option<Instant>,
}

impl Inner {
    fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.port = None;
    }
}

impl Drop for WhisperServer {
    fn drop(&mut self) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.stop();
        }
    }
}

impl WhisperServer {
    pub fn new(executable: PathBuf, model: PathBuf, idle: Duration) -> Arc<WhisperServer> {
        let server = Arc::new(WhisperServer { executable, model, idle, inner: Mutex::default() });
        let weak: Weak<WhisperServer> = Arc::downgrade(&server);
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_secs(5));
            let Some(server) = weak.upgrade() else { return };
            let mut inner = server.inner.lock().unwrap();
            let idle = inner.last_used.map_or(true, |at| at.elapsed() >= server.idle);
            if inner.child.is_some() && inner.uses == 0 && idle {
                inner.stop();
            }
        });
        server
    }

    pub fn matches(&self, executable: &Path, model: &Path) -> bool {
        self.executable == executable && self.model == model
    }

    /// Called when recording starts, so the server is ready by the time it ends.
    pub fn warm_up(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.last_used = Some(Instant::now());
        self.launch_if_needed(&mut inner);
    }

    pub fn stop(&self) {
        self.inner.lock().unwrap().stop();
    }

    fn launch_if_needed(&self, inner: &mut Inner) {
        if let Some(child) = inner.child.as_mut() {
            if matches!(child.try_wait(), Ok(None)) {
                return;
            }
        }
        inner.stop();
        let Some(port) = free_port() else { return };
        let mut command = Command::new(&self.executable);
        command
            .arg("-m")
            .arg(&self.model)
            .args(["--host", "127.0.0.1", "--port", &port.to_string(), "-bs", "5", "-bo", "5"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        if let Ok(child) = hide_console(&mut command).spawn() {
            #[cfg(windows)]
            crate::job::tie_to_app(&child);
            inner.child = Some(child);
            inner.port = Some(port);
        }
    }

    /// Returns the port once the server accepts connections.
    fn begin_use(&self, cancel: &CancelFlag) -> Result<u16, Error> {
        let port = {
            let mut inner = self.inner.lock().unwrap();
            self.launch_if_needed(&mut inner);
            inner.uses += 1;
            inner.port
        };
        let port = port.ok_or_else(|| Error::failed("whisper-server didn't start."))?;
        // Loading the model can take a few seconds on a slow PC, the first time.
        let deadline = Instant::now() + Duration::from_secs(20);
        let address = SocketAddr::from(([127, 0, 0, 1], port));
        while Instant::now() < deadline {
            cancel.check()?;
            if TcpStream::connect_timeout(&address, Duration::from_millis(200)).is_ok() {
                return Ok(port);
            }
            if let Some(child) = self.inner.lock().unwrap().child.as_mut() {
                if !matches!(child.try_wait(), Ok(None)) {
                    return Err(Error::failed("whisper-server stopped while starting."));
                }
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        Err(Error::failed("whisper-server didn't become ready."))
    }

    fn end_use(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.uses = inner.uses.saturating_sub(1);
        inner.last_used = Some(Instant::now());
    }

    #[cfg(test)]
    fn is_running(&self) -> bool {
        self.inner.lock().unwrap().child.is_some()
    }
}

fn free_port() -> Option<u16> {
    TcpListener::bind("127.0.0.1:0").ok()?.local_addr().ok().map(|a| a.port())
}

/// Finds the right server for the current settings, and stops one that no longer fits.
#[derive(Default)]
pub struct ServerHost {
    server: Mutex<Option<Arc<WhisperServer>>>,
}

impl ServerHost {
    pub fn server(&self, executable: &Path, model: &Path) -> Arc<WhisperServer> {
        let mut slot = self.server.lock().unwrap();
        if let Some(server) = slot.as_ref() {
            if server.matches(executable, model) {
                return server.clone();
            }
        }
        if let Some(old) = slot.take() {
            old.stop();
        }
        let server = WhisperServer::new(executable.to_path_buf(), model.to_path_buf(), Duration::from_secs(300));
        *slot = Some(server.clone());
        server
    }

    pub fn current(&self) -> Option<Arc<WhisperServer>> {
        self.server.lock().unwrap().clone()
    }

    pub fn stop(&self) {
        if let Some(server) = self.server.lock().unwrap().take() {
            server.stop();
        }
    }
}

/// Transcribes with the running server, and uses whisper-cli if anything goes wrong.
pub struct WhisperServerTranscriber {
    pub server: Arc<WhisperServer>,
    pub language: String,
    pub fallback: Box<dyn Transcriber>,
}

impl WhisperServerTranscriber {
    fn send(&self, wav: &[u8], cancel: &CancelFlag) -> Result<String, Error> {
        let port = self.server.begin_use(cancel);
        let result = port.and_then(|port| {
            let mut form = Multipart::new();
            form.field("language", &self.language);
            form.field("response_format", "json");
            form.wav(wav);
            let (content_type, body) = form.finish();
            let url = format!("http://127.0.0.1:{port}/inference");
            let reply = http::post(Duration::from_secs(300), &url, &[], &content_type, &body, "whisper-server")?;
            http::text_field(&reply, "whisper-server")
        });
        self.server.end_use();
        result
    }
}

impl Transcriber for WhisperServerTranscriber {
    fn name(&self) -> &str {
        "whisper.cpp"
    }

    fn transcribe(&self, wav: &[u8], cancel: &CancelFlag) -> Result<String, Error> {
        match self.send(wav, cancel) {
            Ok(text) => {
                cancel.check()?;
                Ok(text)
            }
            Err(error) => {
                cancel.check()?;
                if error == Error::Cancelled {
                    return Err(error);
                }
                self.server.stop();
                self.fallback.transcribe(wav, cancel)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::SpeechAudio;

    struct Fixed(&'static str);

    impl Transcriber for Fixed {
        fn name(&self) -> &str {
            "fixed"
        }
        fn transcribe(&self, _: &[u8], _: &CancelFlag) -> Result<String, Error> {
            Ok(self.0.into())
        }
    }

    #[test]
    fn broken_server_falls_back_to_cli() {
        let server = WhisperServer::new("/no/such/whisper-server".into(), "/no/model.bin".into(), Duration::from_secs(1));
        let transcriber =
            WhisperServerTranscriber { server: server.clone(), language: "auto".into(), fallback: Box::new(Fixed("from cli")) };
        assert_eq!(transcriber.transcribe(b"RIFF", &CancelFlag::new()).unwrap(), "from cli");
        assert!(!server.is_running());
    }

    #[test]
    fn host_reuses_and_replaces_servers() {
        let host = ServerHost::default();
        let first = host.server(Path::new("/a"), Path::new("/m1"));
        assert!(Arc::ptr_eq(&first, &host.server(Path::new("/a"), Path::new("/m1"))));
        let second = host.server(Path::new("/a"), Path::new("/m2"));
        assert!(!Arc::ptr_eq(&first, &second), "A new model needs a new server");
    }

    /// Runs the real whisper-server when it and a model are installed, as on a
    /// Mac with Homebrew's whisper-cpp. Skips otherwise.
    #[test]
    fn real_server_transcribes_and_stops() {
        let executable = std::env::var_os("HOLDTALK_WHISPER_SERVER")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/opt/homebrew/bin/whisper-server"));
        let model = std::env::var_os("HOLDTALK_MODEL").map(PathBuf::from).unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config/holdtalk/models/ggml-small.bin")
        });
        if !executable.is_file() || !model.is_file() {
            eprintln!("skipped: no whisper-server or model");
            return;
        }
        let server = WhisperServer::new(executable, model, Duration::from_secs(60));
        let transcriber =
            WhisperServerTranscriber { server: server.clone(), language: "en".into(), fallback: Box::new(Fixed("FALLBACK")) };
        let silence = SpeechAudio::new(vec![0.0; 16_000]).wav_data();
        let text = transcriber.transcribe(&silence, &CancelFlag::new()).unwrap();
        assert_ne!(text, "FALLBACK", "The server answered itself");
        assert!(server.is_running());
        server.stop();
        assert!(!server.is_running());
    }
}
