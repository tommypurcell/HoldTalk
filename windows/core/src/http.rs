//! The small amount of HTTP HoldTalk needs: JSON and multipart POSTs.

use crate::Error;
use std::io::Read;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

pub(crate) fn agent(timeout: Duration) -> Result<ureq::Agent, Error> {
    let tls = native_tls::TlsConnector::new().map_err(|e| Error::failed(format!("Secure connections failed: {e}")))?;
    Ok(ureq::AgentBuilder::new().timeout(timeout).tls_connector(Arc::new(tls)).build())
}

/// Sends a POST and returns the reply body. Errors name the service and status
/// only, never the URL or key.
pub(crate) fn post(
    timeout: Duration,
    url: &str,
    headers: &[(&str, &str)],
    content_type: &str,
    body: &[u8],
    service: &str,
) -> Result<String, Error> {
    let mut request = agent(timeout)?.post(url).set("Content-Type", content_type);
    for (name, value) in headers {
        request = request.set(name, value);
    }
    match request.send_bytes(body) {
        Ok(response) => {
            let mut text = String::new();
            response
                .into_reader()
                .take(10 * 1024 * 1024)
                .read_to_string(&mut text)
                .map_err(|_| Error::failed(format!("{service} sent a reply that couldn't be read.")))?;
            Ok(text)
        }
        Err(ureq::Error::Status(code, _)) => Err(Error::failed(format!("{service} returned error {code}."))),
        Err(ureq::Error::Transport(_)) => Err(Error::failed(format!("{service} couldn't be reached."))),
    }
}

pub(crate) struct Multipart {
    boundary: String,
    body: Vec<u8>,
}

impl Multipart {
    pub(crate) fn new() -> Self {
        static COUNT: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        let boundary = format!("holdtalk-{nanos:x}-{}", COUNT.fetch_add(1, Ordering::Relaxed));
        Self { boundary, body: Vec::new() }
    }

    pub(crate) fn field(&mut self, name: &str, value: &str) {
        self.body.extend_from_slice(
            format!("--{}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n", self.boundary)
                .as_bytes(),
        );
    }

    pub(crate) fn wav(&mut self, wav: &[u8]) {
        self.body.extend_from_slice(
            format!(
                "--{}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n",
                self.boundary
            )
            .as_bytes(),
        );
        self.body.extend_from_slice(wav);
        self.body.extend_from_slice(b"\r\n");
    }

    pub(crate) fn finish(mut self) -> (String, Vec<u8>) {
        self.body.extend_from_slice(format!("--{}--\r\n", self.boundary).as_bytes());
        (format!("multipart/form-data; boundary={}", self.boundary), self.body)
    }
}

/// Pulls `"text"` out of a Whisper-style JSON reply.
pub(crate) fn text_field(reply: &str, service: &str) -> Result<String, Error> {
    let value: serde_json::Value =
        serde_json::from_str(reply).map_err(|_| Error::failed(format!("{service} sent a reply that wasn't JSON.")))?;
    value["text"]
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| Error::failed(format!("{service} sent no text.")))
}

/// A one-request HTTP server for tests: records what it was sent and answers
/// with a fixed reply. Nothing leaves the machine.
#[cfg(test)]
pub(crate) mod mock {
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc;

    pub(crate) struct Seen {
        pub head: String,
        pub body: Vec<u8>,
    }

    impl Seen {
        pub(crate) fn header(&self, name: &str) -> Option<String> {
            let prefix = format!("{}:", name.to_lowercase());
            self.head
                .lines()
                .find(|line| line.to_lowercase().starts_with(&prefix))
                .map(|line| line[prefix.len()..].trim().to_string())
        }

        pub(crate) fn body_text(&self) -> String {
            String::from_utf8_lossy(&self.body).into_owned()
        }
    }

    pub(crate) fn serve(status: u16, reply: &str) -> (String, mpsc::Receiver<Seen>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let reply = reply.to_string();
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            let Ok((stream, _)) = listener.accept() else { return };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut head = String::new();
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                    break;
                }
                head.push_str(&line);
            }
            let length = head
                .lines()
                .find_map(|l| l.to_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse().unwrap_or(0)))
                .unwrap_or(0);
            let mut body = vec![0; length];
            let _ = reader.read_exact(&mut body);
            let _ = sender.send(Seen { head, body });
            let mut stream = stream;
            let _ = write!(
                stream,
                "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}",
                reply.len()
            );
        });
        (url, receiver)
    }
}
