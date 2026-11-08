//! The settings file, `%APPDATA%\HoldTalk\config.json`, and the `.env` beside it.
//! Missing settings use the defaults below. Same keys as the Mac app's `Config.swift`.

use crate::hotkey::Hotkey;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fmt;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields, rename_all = "camelCase")]
pub struct Config {
    pub hotkey: String,
    /// "local", "groq" or "openai".
    pub transcriber: String,
    /// "small", "medium", or a full path to a ggml model file.
    pub local_model: String,
    /// Path to whisper-cli.exe. Leave unset to use the copy installed with HoldTalk.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub whisper_path: Option<String>,
    /// "auto" or a language code such as "en".
    pub language: String,
    /// Overrides the default speech model for the groq or openai transcriber.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transcriber_model: Option<String>,

    pub cleanup_enabled: bool,
    /// "auto" uses the first key found in .env. Otherwise "groq", "anthropic" or "openai".
    pub cleanup_provider: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cleanup_model: Option<String>,
    /// "sentence", "lowercase" or "preserve".
    pub casing: String,
    pub cleanup_timeout_seconds: f64,

    /// false leaves the transcript on the clipboard. true puts your old clipboard back.
    pub restore_clipboard: bool,

    /// Recording stops and transcribes at this limit, so nothing records all afternoon.
    pub max_recording_seconds: f64,
    pub tap_max_milliseconds: f64,
    pub double_tap_window_milliseconds: f64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            // Windows can't see fn, and Right Ctrl does nothing when held alone.
            hotkey: "right_ctrl".into(),
            transcriber: "local".into(),
            local_model: "small".into(),
            whisper_path: None,
            language: "auto".into(),
            transcriber_model: None,
            cleanup_enabled: true,
            cleanup_provider: "auto".into(),
            cleanup_model: None,
            casing: "sentence".into(),
            cleanup_timeout_seconds: 8.0,
            restore_clipboard: false,
            max_recording_seconds: 300.0,
            tap_max_milliseconds: 250.0,
            double_tap_window_milliseconds: 350.0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Invalid(pub String);

impl fmt::Display for Invalid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Invalid {}

impl Config {
    /// Reads and checks settings. A typo fails loudly instead of silently using a default.
    pub fn parse(text: &str) -> Result<Config, Invalid> {
        let value: serde_json::Value =
            serde_json::from_str(text).map_err(|e| Invalid(format!("The settings file isn't valid JSON: {e}")))?;
        if !value.is_object() {
            return Err(Invalid("The settings file must be one JSON object.".into()));
        }
        let config: Config = serde_json::from_value(value).map_err(|e| {
            let message = e.to_string();
            // serde says "unknown field `x`, expected one of ..."; keep just the name.
            match message.split('`').nth(1) {
                Some(name) if message.starts_with("unknown field") => Invalid(format!("Unknown setting \"{name}\".")),
                _ => Invalid(format!("Settings: {message}")),
            }
        })?;
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<(), Invalid> {
        Hotkey::parse(&self.hotkey).map_err(|e| Invalid(e.0))?;
        let check = |ok: bool, message: &str| if ok { Ok(()) } else { Err(Invalid(message.into())) };
        check(
            ["local", "groq", "openai"].contains(&self.transcriber.as_str()),
            "transcriber must be local, groq or openai.",
        )?;
        check(
            ["auto", "groq", "anthropic", "openai"].contains(&self.cleanup_provider.as_str()),
            "cleanupProvider must be auto, groq, anthropic or openai.",
        )?;
        check(
            ["sentence", "lowercase", "preserve"].contains(&self.casing.as_str()),
            "casing must be sentence, lowercase or preserve.",
        )?;
        check(self.max_recording_seconds > 0.0, "maxRecordingSeconds must be above 0.")?;
        check(self.cleanup_timeout_seconds > 0.0, "cleanupTimeoutSeconds must be above 0.")?;
        check(self.tap_max_milliseconds > 0.0, "tapMaxMilliseconds must be above 0.")?;
        check(self.double_tap_window_milliseconds > 0.0, "doubleTapWindowMilliseconds must be above 0.")
    }

    pub fn model_path(&self, paths: &Paths) -> PathBuf {
        if self.local_model.contains('/') || self.local_model.contains('\\') {
            return PathBuf::from(&self.local_model);
        }
        paths.models.join(format!("ggml-{}.bin", self.local_model))
    }

    /// whisper-cli.exe: the configured one, or the copy in HoldTalk's install folder.
    pub fn whisper_cli(&self, bundled_folder: Option<&Path>) -> Option<PathBuf> {
        let candidate = match &self.whisper_path {
            Some(path) => PathBuf::from(path),
            None => bundled_folder?.join(executable("whisper-cli")),
        };
        candidate.is_file().then_some(candidate)
    }
}

/// Adds .exe on Windows.
pub fn executable(name: &str) -> String {
    if cfg!(windows) {
        format!("{name}.exe")
    } else {
        name.to_string()
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Paths {
    pub folder: PathBuf,
    pub config: PathBuf,
    pub env: PathBuf,
    pub models: PathBuf,
}

impl Paths {
    pub fn new(folder: PathBuf) -> Paths {
        Paths {
            config: folder.join("config.json"),
            env: folder.join(".env"),
            models: folder.join("models"),
            folder,
        }
    }

    /// `%APPDATA%\HoldTalk` on Windows. Elsewhere a dev folder, so trying the
    /// Windows build on a Mac never touches the Mac app's settings.
    pub fn standard() -> Paths {
        let folder = match std::env::var_os("APPDATA") {
            Some(appdata) if cfg!(windows) => PathBuf::from(appdata).join("HoldTalk"),
            _ => {
                let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
                home.join(".config").join("holdtalk-windows-dev")
            }
        };
        Paths::new(folder)
    }
}

/// Reads simple KEY=value lines. Blank values count as no key.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct EnvFile {
    values: HashMap<String, String>,
}

impl EnvFile {
    pub fn parse(text: &str) -> EnvFile {
        let mut values = HashMap::new();
        for line in text.lines() {
            let mut entry = line.trim();
            if entry.starts_with('#') {
                continue;
            }
            if let Some(rest) = entry.strip_prefix("export ") {
                entry = rest;
            }
            let Some((key, value)) = entry.split_once('=') else { continue };
            let key = key.trim();
            let mut value = value.trim();
            let quoted = value.len() >= 2
                && (value.starts_with('"') && value.ends_with('"') || value.starts_with('\'') && value.ends_with('\''));
            if quoted {
                value = &value[1..value.len() - 1];
            }
            if !key.is_empty() && !value.is_empty() {
                values.insert(key.to_string(), value.to_string());
            }
        }
        EnvFile { values }
    }

    pub fn load(path: &Path) -> EnvFile {
        EnvFile::parse(&std::fs::read_to_string(path).unwrap_or_default())
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.values.get(key).map(String::as_str)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_config_uses_defaults() {
        let config = Config::parse("{}").unwrap();
        assert_eq!(config, Config::default());
        assert_eq!(config.hotkey, "right_ctrl");
        assert_eq!(config.max_recording_seconds, 300.0);
        assert!(!config.restore_clipboard, "Leaves the transcript on the clipboard by default");
    }

    #[test]
    fn config_reads_values_and_round_trips() {
        let config = Config::parse(r#"{"hotkey": "right_option", "transcriber": "groq", "restoreClipboard": true}"#).unwrap();
        assert_eq!(config.hotkey, "right_option");
        assert_eq!(config.transcriber, "groq");
        assert!(config.restore_clipboard);
        assert_eq!(Config::parse(&serde_json::to_string(&config).unwrap()).unwrap(), config);
    }

    #[test]
    fn config_rejects_mistakes() {
        for bad in [
            r#"{"hotkye": "right_ctrl"}"#,
            r#"{"hotkey": "fn"}"#,
            r#"{"transcriber": "siri"}"#,
            r#"{"casing": "loud"}"#,
            r#"{"maxRecordingSeconds": 0}"#,
            r#"{"cleanupEnabled": "yes"}"#,
            "[]",
            "not json",
        ] {
            assert!(Config::parse(bad).is_err(), "{bad}");
        }
        assert_eq!(Config::parse(r#"{"hotkye": 1}"#).unwrap_err().0, "Unknown setting \"hotkye\".");
    }

    #[test]
    fn model_names_and_paths() {
        let paths = Paths::new(PathBuf::from("base"));
        let mut config = Config::default();
        assert_eq!(config.model_path(&paths), PathBuf::from("base").join("models").join("ggml-small.bin"));
        config.local_model = "medium".into();
        assert!(config.model_path(&paths).ends_with("ggml-medium.bin"));
        config.local_model = r"C:\models\custom.bin".into();
        assert_eq!(config.model_path(&paths), PathBuf::from(r"C:\models\custom.bin"));
    }

    #[test]
    fn env_file() {
        let env = EnvFile::parse(
            "# comment\nGROQ_API_KEY=abc\nexport OPENAI_API_KEY=\"def\"\nANTHROPIC_API_KEY = 'g=h'\nEMPTY=\nnot a line\n",
        );
        assert_eq!(env.get("GROQ_API_KEY"), Some("abc"));
        assert_eq!(env.get("OPENAI_API_KEY"), Some("def"));
        assert_eq!(env.get("ANTHROPIC_API_KEY"), Some("g=h"));
        assert_eq!(env.get("EMPTY"), None);
        assert_eq!(env.get("MISSING"), None);
    }
}
