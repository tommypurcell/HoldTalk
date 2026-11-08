//! Speech audio in the format Whisper wants: 16 kHz, mono.

pub const SAMPLE_RATE: u32 = 16_000;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct SpeechAudio {
    pub samples: Vec<f32>,
}

impl SpeechAudio {
    pub fn new(samples: Vec<f32>) -> Self {
        Self { samples }
    }

    pub fn duration(&self) -> f64 {
        self.samples.len() as f64 / SAMPLE_RATE as f64
    }

    pub fn peak(&self) -> f32 {
        self.samples.iter().fold(0.0, |peak, s| peak.max(s.abs()))
    }

    /// Too short or too quiet to hold speech. Whisper tends to invent text for
    /// silence, so this audio is never sent to it.
    pub fn is_likely_empty(&self) -> bool {
        self.duration() < 0.3 || self.peak() < 0.003
    }

    /// A complete 16-bit PCM WAV file.
    pub fn wav_data(&self) -> Vec<u8> {
        let byte_count = (self.samples.len() * 2) as u32;
        let mut data = Vec::with_capacity(44 + byte_count as usize);
        data.extend_from_slice(b"RIFF");
        data.extend_from_slice(&(36 + byte_count).to_le_bytes());
        data.extend_from_slice(b"WAVEfmt ");
        data.extend_from_slice(&16u32.to_le_bytes());
        data.extend_from_slice(&1u16.to_le_bytes()); // PCM
        data.extend_from_slice(&1u16.to_le_bytes()); // mono
        data.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
        data.extend_from_slice(&(SAMPLE_RATE * 2).to_le_bytes());
        data.extend_from_slice(&2u16.to_le_bytes());
        data.extend_from_slice(&16u16.to_le_bytes());
        data.extend_from_slice(b"data");
        data.extend_from_slice(&byte_count.to_le_bytes());
        for sample in &self.samples {
            let pcm = (sample.clamp(-1.0, 1.0) * i16::MAX as f32) as i16;
            data.extend_from_slice(&pcm.to_le_bytes());
        }
        data
    }
}

/// Converts whatever the microphone delivers to 16 kHz mono, one buffer at a time.
///
/// Each output sample is the average of the input samples around it. That is
/// a simple low-pass filter, enough to keep high pitches from folding down into
/// the speech band, and it needs no extra library.
pub struct Resampler {
    channels: usize,
    /// Input samples per output sample.
    step: f64,
    /// Mono input not yet fully used.
    pending: Vec<f32>,
    /// Where the next output sample sits, as a position in `pending`.
    next: f64,
}

impl Resampler {
    pub fn new(input_rate: u32, channels: u16) -> Self {
        let step = input_rate as f64 / SAMPLE_RATE as f64;
        Self { channels: channels.max(1) as usize, step, pending: Vec::new(), next: step / 2.0 }
    }

    /// Takes interleaved samples and returns the 16 kHz mono samples they complete.
    pub fn convert(&mut self, interleaved: &[f32]) -> Vec<f32> {
        let channels = self.channels;
        self.pending.extend(
            interleaved.chunks_exact(channels).map(|frame| frame.iter().sum::<f32>() / channels as f32),
        );
        self.drain(false)
    }

    /// Returns what's held back. Without this the end of every recording,
    /// usually the last word, gets clipped.
    pub fn flush(&mut self) -> Vec<f32> {
        let out = self.drain(true);
        self.pending.clear();
        self.next = self.step / 2.0;
        out
    }

    fn drain(&mut self, flush: bool) -> Vec<f32> {
        let half = (self.step / 2.0).max(0.5);
        let available = self.pending.len() as f64;
        let mut out = Vec::new();
        loop {
            let center = self.next;
            if (!flush && center + half > available) || (flush && center >= available) {
                break;
            }
            let start = (center - half).floor().max(0.0) as usize;
            let end = ((center + half).ceil() as usize).min(self.pending.len()).max(start + 1);
            let window = &self.pending[start..end.min(self.pending.len())];
            out.push(window.iter().sum::<f32>() / window.len().max(1) as f32);
            self.next += self.step;
        }
        // Drop input that no future output sample can reach.
        let used = ((self.next - half).floor().max(0.0) as usize).min(self.pending.len());
        self.pending.drain(..used);
        self.next -= used as f64;
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wav_header_and_length() {
        let data = SpeechAudio::new(vec![0.0, 1.0, -1.0, 5.0]).wav_data();
        assert_eq!(data.len(), 44 + 8);
        assert_eq!(&data[..4], b"RIFF");
        assert_eq!(data[24], 0x80, "16000 Hz, low byte");
        assert_eq!(data[25], 0x3E, "16000 Hz, high byte");
        let samples: Vec<i16> = data[44..].chunks(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect();
        assert_eq!(samples, vec![0, i16::MAX, -i16::MAX, i16::MAX], "Loud samples clip instead of overflowing");
    }

    #[test]
    fn silence_detection() {
        assert!(SpeechAudio::new(vec![]).is_likely_empty());
        assert!(SpeechAudio::new(vec![0.0; 32_000]).is_likely_empty(), "silent");
        assert!(SpeechAudio::new(vec![0.5; 1000]).is_likely_empty(), "too short");
        assert!(!SpeechAudio::new(vec![0.1; 32_000]).is_likely_empty());
    }

    fn tone(rate: u32, channels: u16, seconds: f64) -> Vec<f32> {
        let frames = (rate as f64 * seconds) as usize;
        (0..frames)
            .flat_map(|i| {
                let value = 0.5 * (2.0 * std::f64::consts::PI * 440.0 * i as f64 / rate as f64).sin() as f32;
                std::iter::repeat(value).take(channels as usize)
            })
            .collect()
    }

    fn check_resampled(rate: u32, channels: u16) {
        let input = tone(rate, channels, 2.0);
        let mut resampler = Resampler::new(rate, channels);
        let mut output = Vec::new();
        // Mic-sized buffers of 480 frames, as WASAPI delivers every 10 ms at 48 kHz.
        for buffer in input.chunks(480 * channels as usize) {
            output.extend(resampler.convert(buffer));
        }
        let before_flush = output.len();
        output.extend(resampler.flush());
        assert!(output.len() >= before_flush, "Flush never loses audio");
        assert!((output.len() as f64 - 32_000.0).abs() <= 3.0, "2 seconds at 16 kHz, got {}", output.len());
        let settled = &output[1600..];
        let crossings = settled.windows(2).filter(|w| (w[0] < 0.0) != (w[1] < 0.0)).count() as f64;
        let per_second = crossings / 2.0 / (settled.len() as f64 / 16_000.0);
        assert!((per_second - 440.0).abs() < 3.0, "Pitch per second: {per_second}");
        assert!(settled.iter().cloned().fold(0.0, f32::max) > 0.45, "Downmixing mustn't lose the signal");
    }

    #[test]
    fn resampler_keeps_length_and_pitch() {
        check_resampled(48_000, 2);
        check_resampled(44_100, 1);
        check_resampled(16_000, 1);
    }
}
