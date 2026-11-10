import AVFoundation
import Foundation

/// Speech audio in the format Whisper wants: 16 kHz, mono.
public struct SpeechAudio {
    public static let sampleRate = 16_000.0
    public var samples: [Float]

    public init(samples: [Float]) { self.samples = samples }

    public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
    public var peak: Float { samples.reduce(0) { max($0, abs($1)) } }

    /// Too short or too quiet to hold speech. Whisper tends to invent text for
    /// silence, so this audio is never sent to it.
    public var isLikelyEmpty: Bool { duration < 0.3 || peak < 0.003 }

    /// A complete 16-bit PCM WAV file.
    public func wavData() -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(Self.sampleRate))
        append(UInt32(Self.sampleRate) * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(byteCount)
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * Float(Int16.max)).littleEndian }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

/// Converts whatever the microphone delivers to 16 kHz mono, one buffer at a time.
public final class SpeechResampler {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    /// Set when only the first channel is converted. See `init`.
    private let firstChannelFormat: AVAudioFormat?

    /// With voice processing on, the Mac delivers the same cleaned-up voice on
    /// every channel, and downmixing those channels gives silence. Pass
    /// `firstChannelOnly` then, to convert channel 0 alone.
    public init?(inputFormat: AVAudioFormat, firstChannelOnly: Bool = false) {
        var source = inputFormat
        if firstChannelOnly, inputFormat.channelCount > 1 {
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: inputFormat.sampleRate,
                                           channels: 1,
                                           interleaved: false) else { return nil }
            source = mono
            firstChannelFormat = mono
        } else {
            firstChannelFormat = nil
        }
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: SpeechAudio.sampleRate,
                                         channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: source, to: output) else { return nil }
        converter.downmix = true
        self.converter = converter
        outputFormat = output
    }

    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let input = firstChannel(of: buffer) else { return [] }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        var supplied = false
        return run(capacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024) { status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
    }

    /// The converter's filter holds back the newest audio. Without this, the end
    /// of every recording, usually the last word, gets clipped.
    public func flush() -> [Float] {
        run(capacity: 8192) { status in
            status.pointee = .endOfStream
            return nil
        }
    }

    private func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let firstChannelFormat else { return buffer }
        guard let mono = AVAudioPCMBuffer(pcmFormat: firstChannelFormat, frameCapacity: buffer.frameLength),
              let from = buffer.floatChannelData?[0],
              let to = mono.floatChannelData?[0] else { return nil }
        to.update(from: from, count: Int(buffer.frameLength))
        mono.frameLength = buffer.frameLength
        return mono
    }

    private func run(capacity: AVAudioFrameCount,
                     input: @escaping (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?) -> [Float] {
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in input(status) }
        guard error == nil, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
