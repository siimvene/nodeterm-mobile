import Foundation

/// PCM encoding + the mandatory recording bound for the server-whisper path (SPEC §5.5 / §4.10).
/// Pure (no AVFoundation) so the cap logic is testable; capture lives in `DictationRecorder`.
///
/// Wire encoding: base64 string of little-endian Int16 samples, 16 kHz, mono. The server frame cap
/// is 8 MiB and an oversized frame closes the WHOLE socket (code 1009), dropping every open
/// terminal on that server — so the recording MUST be bounded BEFORE sending.
public enum PcmAudio {
    /// Fixed capture rate the server expects (SPEC §5.5).
    public static let sampleRate = 16_000
    /// ~2 minute cap (SPEC §5.5): base64 Int16 @16 kHz ≈ 42.7 KB/s ⇒ ~5.1 MB base64, under 8 MiB.
    public static let maxSeconds = 120
    /// Hard sample cap derived from the second bound.
    public static let maxSamples = sampleRate * maxSeconds

    /// Truncate a sample buffer to the ~2 min cap (SPEC §5.5). Applied before encode/send.
    public static func capped(_ samples: [Int16]) -> [Int16] {
        samples.count <= maxSamples ? samples : Array(samples.prefix(maxSamples))
    }

    /// Encode Int16 samples to little-endian bytes.
    public static func encodeInt16LE(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            let u = UInt16(bitPattern: s)
            data.append(UInt8(u & 0x00FF))
            data.append(UInt8((u >> 8) & 0x00FF))
        }
        return data
    }

    /// Convert normalized Float samples (-1…1) to Int16 with clamping.
    public static func floatToInt16(_ floats: [Float]) -> [Int16] {
        floats.map { f in
            let scaled = f * 32767.0
            if scaled >= 32767.0 { return Int16.max }
            if scaled <= -32768.0 { return Int16.min }
            return Int16(scaled.rounded())
        }
    }

    /// The base64 payload for `speech:transcribe` (SPEC §5.5), already capped.
    public static func transcribeBase64(_ samples: [Int16]) -> String {
        encodeInt16LE(capped(samples)).base64EncodedString()
    }

    /// Seconds of audio a sample count represents (for the countdown display).
    public static func seconds(sampleCount: Int) -> Double {
        Double(sampleCount) / Double(sampleRate)
    }
}
