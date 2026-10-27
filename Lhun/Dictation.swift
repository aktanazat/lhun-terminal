import AVFAudio
import OSLog
import Speech
import SwiftUI

private let log = Logger(subsystem: "com.aktanazat.lhun", category: "dictation")

/// Dictation, from the key row's mic key or Dictate in the palette. Speech becomes text on the device,
/// with SpeechAnalyzer; no audio leaves it. The words so far show in a bubble above the key row. The mic
/// key again, or a tap on the bubble, types them at the cursor the way a paste goes in, without Return;
/// Esc or a tap anywhere else drops them. The microphone, the audio engine and the analyzer exist only
/// while it listens.
@MainActor @Observable
final class Dictation {
    enum Phase: Equatable {
        /// Asking for the microphone, and the first time, fetching the language's speech model.
        case starting
        case listening
        /// Done listening; the last words are being settled.
        case finishing
    }

    enum Problem: LocalizedError {
        case noMicrophone
        case unsupported

        var errorDescription: String? {
            switch self {
            case .noMicrophone: "Dictation needs the microphone. Allow it for Lhûn in Settings."
            case .unsupported: "This device can't turn speech into text here."
            }
        }
    }

    /// The session the words go to.
    let session: SessionRef
    private(set) var phase = Phase.starting
    /// Words the analyzer has settled on.
    private(set) var settled = ""
    /// Its guess at the words after them, which changes as more audio comes in.
    private(set) var guess = ""
    /// Told once, with why, when listening could not start or stopped by itself.
    @ObservationIgnored var onFailure: ((String) -> Void)?

    @ObservationIgnored private var setup: Task<Void, Never>?
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var feed: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var ended = false

    init(session: SessionRef) {
        self.session = session
    }

    var words: String { settled + guess }

    func start() {
        setup = Task {
            do {
                try await listen()
            } catch {
                fail(error)
            }
        }
    }

    /// Stops listening and returns every word heard, the guess at the last ones settled first.
    func finish() async -> String {
        guard !ended else { return "" }
        ended = true
        phase = .finishing
        await setup?.value
        stopAudio()
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                log.error("finishing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await reading?.value
        release()
        return words.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stops listening and drops what was heard.
    func cancel() {
        guard !ended else { return }
        ended = true
        Task {
            await setup?.value
            stopAudio()
            await analyzer?.cancelAndFinishNow()
            reading?.cancel()
            release()
        }
    }

    private func listen() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw Problem.noMicrophone }
        guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        else { throw Problem.unsupported }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Problem.unsupported
        }
        guard !ended else { return }

        try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
        try AVAudioSession.sharedInstance().setActive(true)
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
        self.feed = feed
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let results = transcriber.results
        reading = Task {
            do {
                for try await result in results {
                    heard(String(result.text.characters), isFinal: result.isFinal)
                }
            } catch {
                log.error("reading failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        try await analyzer.start(inputSequence: input)
        let engine = AVAudioEngine()
        self.engine = engine
        try AudioTap.install(on: engine.inputNode, converting: format, into: feed)
        engine.prepare()
        try engine.start()
        if !ended { phase = .listening }
    }

    private func heard(_ text: String, isFinal: Bool) {
        if isFinal {
            settled += text
            guess = ""
        } else {
            guess = text
        }
    }

    private func fail(_ error: Error) {
        log.error("dictation failed: \(error.localizedDescription, privacy: .public)")
        guard !ended else { return }
        cancel()
        onFailure?(error.localizedDescription)
    }

    private func stopAudio() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        feed?.finish()
    }

    /// Lets go of the microphone, the engine and the analyzer, and gives other apps their audio back.
    private func release() {
        engine = nil
        feed = nil
        analyzer = nil
        reading = nil
        setup = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            log.error("giving the audio back failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Hands the microphone's audio to the analyzer in the format it reads. The audio engine calls the tap
/// on its own thread, so nothing here touches the main actor.
private enum AudioTap {
    static func install(
        on node: AVAudioInputNode, converting format: AVAudioFormat, into feed: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        let natural = node.outputFormat(forBus: 0)
        guard let converter = Converter(from: natural, to: format) else { throw Dictation.Problem.unsupported }
        node.installTap(onBus: 0, bufferSize: 4096, format: natural) { buffer, _ in
            if let converted = converter.convert(buffer) { feed.yield(AnalyzerInput(buffer: converted)) }
        }
    }
}

/// Resamples the microphone's buffers, one at a time and in order, on the audio engine's thread.
private final class Converter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat

    init?(from natural: AVAudioFormat, to format: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: natural, to: format) else { return nil }
        self.converter = converter
        self.format = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = (Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up)
        guard frames > 0, let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        var given = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if given {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, converted.frameLength > 0 else { return nil }
        return converted
    }
}

extension AppModel {
    /// The mic key and Dictate in the palette: listens for the open session, or types what it heard.
    func toggleDictation() {
        if dictation == nil {
            startDictation()
        } else {
            finishDictation()
        }
    }

    private func startDictation() {
        guard let session = selection, selectedTerminal != nil else { return }
        let dictation = Dictation(session: session)
        dictation.onFailure = { [weak self, weak dictation] why in
            guard let self, self.dictation === dictation else { return }
            dictationEnded()
            note(why)
        }
        self.dictation = dictation
        keyRow.showDictating(true)
        dictation.start()
        probe?.record("dictation started")
    }

    /// Types what was heard at the session's cursor, the way a paste goes in.
    func finishDictation() {
        guard let dictation, dictation.phase != .finishing else { return }
        Task {
            let words = await dictation.finish()
            guard self.dictation === dictation else { return }
            dictationEnded()
            if !words.isEmpty { terminals[dictation.session]?.paste(words) }
            probe?.record("dictation typed", details: ["dictated": words])
        }
    }

    /// Esc or a tap away: stops listening and types nothing.
    func cancelDictation() {
        guard let dictation else { return }
        dictation.cancel()
        dictationEnded()
        probe?.record("dictation cancelled")
    }

    /// Esc, from the key row or a keyboard, drops dictation instead of reaching the session: true when it
    /// did.
    func escapeDictation() -> Bool {
        guard dictation != nil else { return false }
        cancelDictation()
        return true
    }

    private func dictationEnded() {
        if dictation != nil { keyRow.showDictating(false) }
        dictation = nil
    }
}

/// The words heard so far, in a bubble above the key row. A tap on it types them; a tap anywhere else
/// drops them.
struct DictationBubble: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if let dictation = model.dictation {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { model.cancelDictation() }
                    .accessibilityHidden(true)
                Button(action: model.finishDictation) {
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.near) {
                        Image(systemName: "mic.fill")
                            .accessibilityHidden(true)
                        Text(text(of: dictation))
                            .foregroundStyle(dictation.words.isEmpty ? .secondary : .primary)
                            .lineLimit(3)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.body)
                    .padding(.horizontal, Metrics.inset)
                    .padding(.vertical, Metrics.near)
                    .frame(maxWidth: 560)
                    .background(Theme.raised, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
                    .lifted()
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Metrics.inset)
                .padding(.bottom, Metrics.inset)
                .accessibilityIdentifier("dictation.bubble")
                .accessibilityValue(dictation.words)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.dictation == nil)
        .onChange(of: model.selection) { model.cancelDictation() }
    }

    private func text(of dictation: Dictation) -> String {
        if !dictation.words.isEmpty { return dictation.words }
        return switch dictation.phase {
        case .starting: "Getting ready…"
        case .listening: "Listening…"
        case .finishing: ""
        }
    }
}
