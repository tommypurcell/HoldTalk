//! A parsed `hotkey` setting: one modifier held alone, or a normal key combination.
//! Codes are Windows virtual-key codes. The Mac names (`right_option`,
//! `right_command`, `cmd`) still work, so a config can be copied between the apps.

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ModifierKey {
    RightCtrl,
    LeftCtrl,
    RightAlt,
    LeftAlt,
    RightShift,
    LeftShift,
    RightWin,
    LeftWin,
}

impl ModifierKey {
    /// The left/right-specific code a low-level keyboard hook reports.
    pub fn virtual_key(self) -> u32 {
        match self {
            ModifierKey::LeftShift => 0xA0,
            ModifierKey::RightShift => 0xA1,
            ModifierKey::LeftCtrl => 0xA2,
            ModifierKey::RightCtrl => 0xA3,
            ModifierKey::LeftAlt => 0xA4,
            ModifierKey::RightAlt => 0xA5,
            ModifierKey::LeftWin => 0x5B,
            ModifierKey::RightWin => 0x5C,
        }
    }

    /// Alt and Win do something when tapped alone (menu bar, Start menu), so the
    /// hook masks those taps.
    pub fn needs_tap_mask(self) -> bool {
        matches!(
            self,
            ModifierKey::RightAlt | ModifierKey::LeftAlt | ModifierKey::RightWin | ModifierKey::LeftWin
        )
    }

    fn named(name: &str) -> Option<Self> {
        Some(match name {
            "right_ctrl" | "right_control" => ModifierKey::RightCtrl,
            "left_ctrl" | "left_control" => ModifierKey::LeftCtrl,
            "right_alt" | "right_option" => ModifierKey::RightAlt,
            "left_alt" | "left_option" => ModifierKey::LeftAlt,
            "right_shift" => ModifierKey::RightShift,
            "left_shift" => ModifierKey::LeftShift,
            "right_win" | "right_command" => ModifierKey::RightWin,
            "left_win" | "left_command" => ModifierKey::LeftWin,
            _ => return None,
        })
    }
}

/// Every virtual-key code that is a modifier, left, right or either.
pub fn is_modifier_key(vk: u32) -> bool {
    matches!(vk, 0x10 | 0x11 | 0x12 | 0xA0..=0xA5 | 0x5B | 0x5C)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ComboModifiers {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub win: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Hotkey {
    Modifier(ModifierKey),
    Combo { key: u32, modifiers: ComboModifiers },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError(pub String);

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ParseError {}

impl Hotkey {
    pub fn parse(text: &str) -> Result<Hotkey, ParseError> {
        let cleaned = text.trim().to_lowercase();
        if cleaned == "fn" {
            return Err(ParseError(
                "Windows can't see the fn key. Use \"right_ctrl\" or another key instead.".into(),
            ));
        }
        if let Some(key) = ModifierKey::named(&cleaned) {
            return Ok(Hotkey::Modifier(key));
        }

        let mut parts: Vec<&str> = cleaned.split('+').map(str::trim).collect();
        let key_name = match parts.pop() {
            Some(name) if !parts.is_empty() => name,
            _ => {
                return Err(ParseError(format!(
                    "Hotkey \"{text}\" isn't valid. Use a single modifier such as \"right_ctrl\" or \
                     \"right_alt\", or a combination such as \"ctrl+alt+space\"."
                )))
            }
        };

        let mut modifiers = ComboModifiers::default();
        for part in parts {
            match part {
                "ctrl" | "control" => modifiers.ctrl = true,
                "alt" | "opt" | "option" => modifiers.alt = true,
                "shift" => modifiers.shift = true,
                "win" | "cmd" | "command" => modifiers.win = true,
                _ => return Err(ParseError(format!("Hotkey \"{text}\": \"{part}\" isn't a modifier."))),
            }
        }
        let key = key_code(key_name)
            .ok_or_else(|| ParseError(format!("Hotkey \"{text}\": unknown key \"{key_name}\".")))?;
        Ok(Hotkey::Combo { key, modifiers })
    }
}

/// Esc is left out on purpose because it cancels.
fn key_code(name: &str) -> Option<u32> {
    let bytes = name.as_bytes();
    if bytes.len() == 1 && (bytes[0].is_ascii_lowercase() || bytes[0].is_ascii_digit()) {
        return Some(bytes[0].to_ascii_uppercase() as u32);
    }
    if let Some(number) = name.strip_prefix('f').and_then(|n| n.parse::<u32>().ok()) {
        if (1..=24).contains(&number) {
            return Some(0x70 + number - 1);
        }
    }
    Some(match name {
        "space" => 0x20,
        "return" | "enter" => 0x0D,
        "tab" => 0x09,
        "delete" | "backspace" => 0x08,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modifiers_and_mac_names() {
        assert_eq!(Hotkey::parse("right_ctrl"), Ok(Hotkey::Modifier(ModifierKey::RightCtrl)));
        assert_eq!(Hotkey::parse("Right_Option"), Ok(Hotkey::Modifier(ModifierKey::RightAlt)));
        assert_eq!(Hotkey::parse("right_command"), Ok(Hotkey::Modifier(ModifierKey::RightWin)));
        assert_eq!(ModifierKey::RightCtrl.virtual_key(), 0xA3);
    }

    #[test]
    fn combinations() {
        let ctrl_alt = ComboModifiers { ctrl: true, alt: true, ..Default::default() };
        assert_eq!(Hotkey::parse("ctrl+option+space"), Ok(Hotkey::Combo { key: 0x20, modifiers: ctrl_alt }));
        let win_shift = ComboModifiers { win: true, shift: true, ..Default::default() };
        assert_eq!(Hotkey::parse("cmd + shift + f13"), Ok(Hotkey::Combo { key: 0x7C, modifiers: win_shift }));
        assert_eq!(
            Hotkey::parse("ctrl+d"),
            Ok(Hotkey::Combo { key: 0x44, modifiers: ComboModifiers { ctrl: true, ..Default::default() } })
        );
    }

    #[test]
    fn mistakes() {
        assert!(Hotkey::parse("space").is_err());
        assert!(Hotkey::parse("banana+space").is_err());
        assert!(Hotkey::parse("ctrl+esc").is_err(), "Esc is reserved for cancel");
        assert!(Hotkey::parse("ctrl+f25").is_err());
        let fn_error = Hotkey::parse("fn").unwrap_err();
        assert!(fn_error.0.contains("right_ctrl"), "fn explains what to use instead");
    }
}
