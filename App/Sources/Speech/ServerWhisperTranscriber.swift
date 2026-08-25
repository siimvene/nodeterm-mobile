import Foundation
import NodetermKit

/// `SpeechTranscribing` over the server-side whisper engine (SPEC §5.5). Depends only on the
/// `RpcClienting` protocol + Kit models, so it is portable and needs no concrete Kit type.
/// The Apple on-device engine (`AppleSpeechTranscriber`) is the default; this is the opt-in
/// per-server alternative.
public struct ServerWhisperTranscriber: SpeechTranscribing {
    private let rpc: RpcClienting

    public init(rpc: RpcClienting) {
        self.rpc = rpc
    }

    /// `speech:transcribe` REQ. `pcm` is base64(Int16 LE, 16 kHz, mono) already bounded by the
    /// caller to ~2 min (SPEC §5.5). Returns text only.
    public func transcribe(pcm: Data, language: String?) async throws -> String {
        // `pcm` here is the raw Int16-LE byte buffer; the wire wants base64 of exactly those bytes.
        let request = SpeechTranscribeRequest(pcm: pcm.base64EncodedString(), language: language)
        let arg = try JSONValue.encoding(request)
        let result = try await rpc.request(RpcMethod.speechTranscribe, [.value(arg)])
        return try result.decoded(as: SpeechTranscribeResult.self).text
    }

    /// `speech:models` REQ — the server's whisper model list (SPEC §5.5).
    public func availableModels() async throws -> [SpeechModelInfo] {
        let result = try await rpc.request(RpcMethod.speechModels, [])
        return try result.decoded(as: [SpeechModelInfo].self)
    }
}

extension JSONValue {
    /// Encode any `Encodable` to a `JSONValue` (for building RPC args from typed models).
    static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
