import Foundation

/// A server-side whisper model descriptor from `speech:models` (SPEC §11.7 / §5.5).
public struct SpeechModelInfo: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var file: String
    public var approxMB: Double
    public var pro: Bool
    public var downloaded: Bool
    public var sizeMB: Double?
    public init(id: String, file: String, approxMB: Double, pro: Bool,
                downloaded: Bool, sizeMB: Double? = nil) {
        self.id = id
        self.file = file
        self.approxMB = approxMB
        self.pro = pro
        self.downloaded = downloaded
        self.sizeMB = sizeMB
    }
}

/// The single argument object of `speech:transcribe` (SPEC §5.5). `pcm` is a base64 string of
/// little-endian Int16 samples, 16 kHz, mono. Bound recordings to ~2 min so the frame stays under
/// the 8 MiB inbound cap (§5.5/§4.10).
public struct SpeechTranscribeRequest: Codable, Sendable, Equatable {
    public var pcm: String       // base64(Int16 LE, 16 kHz, mono)
    public var language: String?
    public init(pcm: String, language: String? = nil) {
        self.pcm = pcm
        self.language = language
    }
}

/// The `speech:transcribe` reply (SPEC §5.5): text only — no audio.
public struct SpeechTranscribeResult: Codable, Sendable, Equatable {
    public var text: String
    public init(text: String) { self.text = text }
}

/// A `speech:progress` event payload (SPEC §6.1).
public struct SpeechProgress: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var pct: Double
    public init(id: String, pct: Double) { self.id = id; self.pct = pct }
}
