//! Downloads Whisper models, the job `scripts/download-model.sh` does on a Mac.

use crate::{CancelFlag, Error};
use sha2::{Digest, Sha256};
use std::io::{Read, Write};
use std::path::Path;
use std::time::Duration;

/// SHA-256 of the files at huggingface.co/ggerganov/whisper.cpp, so a broken or
/// swapped download is caught. Models not listed here are checked by size only.
const KNOWN: &[(&str, &str)] = &[("small", "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b")];

pub fn url(name: &str) -> String {
    format!("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-{name}.bin")
}

/// A model name the download knows how to fetch, as opposed to a file path.
pub fn is_downloadable(name: &str) -> bool {
    !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
}

/// Downloads to a `.part` file next to `target`, checks it, then moves it into
/// place, so a cancelled or failed download never leaves a broken model behind.
/// `progress` gets a fraction from 0 to 1 when the size is known.
pub fn download(name: &str, target: &Path, cancel: &CancelFlag, mut progress: impl FnMut(f64)) -> Result<(), Error> {
    if !is_downloadable(name) {
        return Err(Error::failed(format!("\"{name}\" isn't a model name HoldTalk can download.")));
    }
    let folder = target.parent().ok_or_else(|| Error::failed("The models folder is missing."))?;
    std::fs::create_dir_all(folder).map_err(|e| Error::failed(format!("Couldn't create the models folder: {e}")))?;
    let partial = target.with_extension("bin.part");
    let result = fetch(&url(name), &partial, cancel, &mut progress).and_then(|hash| {
        match KNOWN.iter().find(|(known, _)| *known == name) {
            Some((_, expected)) if *expected != hash => {
                Err(Error::failed("The downloaded model didn't match. Try the download again."))
            }
            _ => Ok(()),
        }
    });
    match result {
        Ok(()) => std::fs::rename(&partial, target).map_err(|e| Error::failed(format!("Couldn't save the model: {e}"))),
        Err(error) => {
            let _ = std::fs::remove_file(&partial);
            Err(error)
        }
    }
}

/// Streams the file to disk and returns its SHA-256 as hex.
fn fetch(url: &str, path: &Path, cancel: &CancelFlag, progress: &mut impl FnMut(f64)) -> Result<String, Error> {
    let agent = crate::http::agent(Duration::from_secs(30))?;
    let response = agent.get(url).call().map_err(|error| match error {
        ureq::Error::Status(code, _) => Error::failed(format!("The model download returned error {code}.")),
        ureq::Error::Transport(_) => Error::failed("The model download couldn't connect. Check the internet."),
    })?;
    let total: Option<u64> = response.header("Content-Length").and_then(|v| v.parse().ok());
    let mut reader = response.into_reader();
    let mut file = std::fs::File::create(path).map_err(|e| Error::failed(format!("Couldn't save the model: {e}")))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 256 * 1024];
    let mut done: u64 = 0;
    loop {
        cancel.check()?;
        let read = reader
            .read(&mut buffer)
            .map_err(|_| Error::failed("The model download stopped. Check the internet and try again."))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        file.write_all(&buffer[..read]).map_err(|e| Error::failed(format!("Couldn't save the model: {e}")))?;
        done += read as u64;
        if let Some(total) = total.filter(|t| *t > 0) {
            progress(done as f64 / total as f64);
        }
    }
    if let Some(total) = total {
        if done != total {
            return Err(Error::failed("The model download was cut short. Try again."));
        }
    }
    file.sync_all().map_err(|e| Error::failed(format!("Couldn't save the model: {e}")))?;
    Ok(hasher.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        assert!(is_downloadable("small"));
        assert!(is_downloadable("large-v3-turbo"));
        assert!(!is_downloadable(r"C:\models\x.bin"));
        assert!(!is_downloadable("../evil"));
        assert_eq!(url("small"), "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin");
    }

    #[test]
    fn refuses_paths() {
        let target = std::env::temp_dir().join("holdtalk-model-test.bin");
        assert!(download("../x", &target, &CancelFlag::new(), |_| {}).is_err());
        assert!(!target.exists());
    }
}
