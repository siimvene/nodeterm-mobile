import SwiftUI
import AVFoundation
import Speech
import NodetermKit

public enum DictationError: Error, Sendable { case unavailable, permissionDenied, noSpeech }

/// Apple on-device dictation (SPEC §9.5 default). Conforms to the same `SpeechTranscribing` contract
/// as the server engine so the two are interchangeable — both take a FINISHED Int16-LE 16 kHz mono
/// PCM buffer. Recognition is forced on-device where the model supports it.
public struct AppleSpeechTranscriber: SpeechTranscribing {
    public init() {}

    public func transcribe(pcm: Data, language: String?) async throws -> String {
        let locale = language.map(Locale.init(identifier:)) ?? Locale.current
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else { throw DictationError.unavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = false

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Double(PcmAudio.sampleRate),
                                         channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(pcm.count / 2))
        else { throw DictationError.unavailable }
        buffer.frameLength = AVAudioFrameCount(pcm.count / 2)
        pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress, let dst = buffer.int16ChannelData?[0] {
                memcpy(dst, base, pcm.count)
            }
        }
        request.append(buffer)
        request.endAudio()

        return try await withCheckedThrowingContinuation { cont in
            var settled = false
            recognizer.recognitionTask(with: request) { result, error in
                if settled { return }
                if let error { settled = true; cont.resume(throwing: error); return }
                if let result, result.isFinal {
                    settled = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    public func availableModels() async throws -> [SpeechModelInfo] { [] }   // Apple engine: none
}

/// Thread-safe sample accumulator for the audio tap. `@unchecked Sendable`: every access is guarded
/// by `lock`, and no field is touched outside those critical sections.
private final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int16] = []
    func append(_ s: [Int16]) { lock.lock(); samples.append(contentsOf: s); lock.unlock() }
    func snapshot() -> [Int16] { lock.lock(); defer { lock.unlock() }; return samples }
    var count: Int { lock.lock(); defer { lock.unlock() }; return samples.count }
}

/// Holds the (non-Sendable) `AVAudioConverter` + target format so the tap block captures only a
/// Sendable value. `@unchecked Sendable`: touched exclusively on the single audio render thread the
/// tap runs on — never concurrently.
private final class ConverterBox: @unchecked Sendable {
    let converter: AVAudioConverter
    let target: AVAudioFormat
    init?(from input: AVAudioFormat) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Double(PcmAudio.sampleRate),
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: target) else { return nil }
        self.target = target
        self.converter = converter
    }
}

/// Microphone capture → 16 kHz mono Int16 PCM (SPEC §5.5/§9.5), with the ~2 min cap enforced BEFORE
/// anything is sent. Publishes the elapsed seconds for the countdown.
@MainActor
public final class DictationRecorder: ObservableObject {
    @Published public private(set) var seconds: Double = 0
    @Published public private(set) var isRecording = false

    private let engine = AVAudioEngine()
    private let buffer = SampleBuffer()
    private var timer: Timer?

    public init() {}

    /// The maximum recording length (SPEC §5.5) — surfaced for the countdown UI.
    public var maxSeconds: Double { Double(PcmAudio.maxSeconds) }

    public func requestPermission() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let mic = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
        return speech && mic
    }

    public func start() throws {
        guard !isRecording else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let box = ConverterBox(from: inputFormat) else { throw DictationError.unavailable }

        let buffer = self.buffer
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { pcmBuffer, _ in
            let ratio = box.target.sampleRate / pcmBuffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio + 1024)
            guard let out = AVAudioPCMBuffer(pcmFormat: box.target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            box.converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return pcmBuffer
            }
            if error != nil { return }
            let n = Int(out.frameLength)
            if n > 0, let ch = out.int16ChannelData?[0] {
                buffer.append(Array(UnsafeBufferPointer(start: ch, count: n)))
            }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
        seconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        seconds = PcmAudio.seconds(sampleCount: buffer.count)
        if seconds >= maxSeconds { _ = stop() }   // hard cap BEFORE send (SPEC §5.5)
    }

    /// Stop and return the capped PCM buffer (Int16 LE 16 kHz mono), ready for either engine.
    @discardableResult
    public func stop() -> Data {
        guard isRecording else { return Data() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        timer?.invalidate(); timer = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let capped = PcmAudio.capped(buffer.snapshot())   // enforce cap even if the timer missed
        return PcmAudio.encodeInt16LE(capped)
    }
}

/// The dictation review sheet (SPEC §9.5): record with a visible countdown, transcribe via the
/// chosen engine, land the text in an EDITABLE field with Send / Insert. NOTHING auto-submits
/// (SPEC §7.6/§9.5) — the user always decides.
public struct DictationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = DictationRecorder()
    @ObservedObject var settings: AppSettings
    let runtime: ServerRuntime
    /// (text, submit) — submit=true → send-text enter:true; false → enter:false (insert).
    let deliver: (String, Bool) -> Void

    @State private var reviewText = ""
    @State private var transcribing = false
    @State private var errorText: String?
    @State private var permissionDenied = false

    private var engine: AppSettings.SpeechEngine { settings.speechEngine(forServer: runtime.profile.id) }

    public init(runtime: ServerRuntime, settings: AppSettings, deliver: @escaping (String, Bool) -> Void) {
        self.runtime = runtime
        self.settings = settings
        self.deliver = deliver
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                engineBadge
                if permissionDenied {
                    ContentUnavailableView("Microphone access needed",
                                           systemImage: "mic.slash",
                                           description: Text("Enable microphone and speech recognition in Settings."))
                } else {
                    countdown
                    recordButton
                    reviewField
                }
                if let errorText { Text(errorText).font(.caption).foregroundStyle(Theme.needsYou) }
                Spacer()
            }
            .padding(20)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Dictate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel() } }
            }
            .task {
                let ok = await recorder.requestPermission()
                permissionDenied = !ok
                if ok { try? recorder.start() }
            }
            .onDisappear {
                // Interactive swipe-dismiss never hits the Cancel button — the mic must not stay
                // hot after the sheet is gone (recording auto-starts in .task above). Discarding
                // the buffer is correct: nothing may be sent without an explicit tap (SPEC §7.6).
                if recorder.isRecording { _ = recorder.stop() }
            }
        }
    }

    private var engineBadge: some View {
        Text(engine.label).font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Theme.card).clipShape(Capsule()).foregroundStyle(Theme.textSecondary)
    }

    private var countdown: some View {
        // Visible countdown toward the ~2 min cap (SPEC §5.5).
        let remaining = max(recorder.maxSeconds - recorder.seconds, 0)
        return VStack(spacing: 6) {
            Text(recorder.isRecording ? "Listening…" : (reviewText.isEmpty ? "Tap to record" : "Review"))
                .font(.headline).foregroundStyle(Theme.textPrimary)
            if recorder.isRecording {
                Text("\(Int(remaining))s left").font(.caption).monospacedDigit()
                    .foregroundStyle(remaining < 15 ? Theme.needsYou : Theme.textSecondary)
            }
        }
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording { Task { await finishRecording() } }
        } label: {
            Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                .font(.system(size: 72)).foregroundStyle(recorder.isRecording ? Theme.needsYou : Theme.accent)
        }
        .disabled(!recorder.isRecording && transcribing)
        .overlay { if transcribing { ProgressView().tint(Theme.accent) } }
    }

    @ViewBuilder private var reviewField: some View {
        if !reviewText.isEmpty || (!recorder.isRecording && !transcribing) {
            VStack(spacing: 12) {
                TextEditor(text: $reviewText)
                    .frame(minHeight: 120).scrollContentBackground(.hidden)
                    .padding(10).card()
                HStack(spacing: 12) {
                    Button("Insert") { deliver(reviewText, false); dismiss() }   // enter:false (§7.6)
                        .buttonStyle(.bordered).tint(Theme.accent)
                    Button("Send") { deliver(reviewText, true); dismiss() }       // enter:true
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                }
                .disabled(reviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Nothing sends until you tap Send.").font(.caption2).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func finishRecording() async {
        let pcm = recorder.stop()
        guard !pcm.isEmpty else { return }
        transcribing = true; defer { transcribing = false }
        do {
            let transcriber = runtime.speechTranscriber(engine)
            let text = try await transcriber.transcribe(pcm: pcm, language: nil)
            reviewText = text
        } catch { errorText = "Couldn't transcribe. Try again or switch engine in Settings." }
    }

    private func cancel() {
        if recorder.isRecording { _ = recorder.stop() }
        dismiss()
    }
}
