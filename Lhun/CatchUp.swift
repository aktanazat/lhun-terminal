import Foundation
import FoundationModels

/// "Catch Up": at most three plain sentences on what ran in a session and how it ended, or what it asks,
/// written on this device by Apple's on-device model from the session's last 200 lines. Nothing leaves the
/// device, and the model goes as soon as the summary is written.
enum CatchUp {
    /// How far a summary has got.
    enum State {
        case reading
        case writing
        case written(String)
        case unavailable(Unavailable)
        case failed(String)

        var text: String {
            switch self {
            case .reading: "Reading its last 200 lines…"
            case .writing: "Writing a summary…"
            case .written(let summary): summary
            case .unavailable(let reason): reason.message
            case .failed(let message): message
            }
        }

        var isWritten: Bool {
            if case .written = self { true } else { false }
        }

        /// Whether asking again might go better.
        var canRetry: Bool {
            switch self {
            case .unavailable, .failed: true
            case .reading, .writing, .written: false
            }
        }
    }

    /// Why this device can't write a summary now.
    enum Unavailable {
        case notEligible
        case off
        case downloading
        case other

        /// Nil when the on-device model is ready.
        static var current: Unavailable? {
            switch SystemLanguageModel.default.availability {
            case .available: nil
            case .unavailable(.deviceNotEligible): .notEligible
            case .unavailable(.appleIntelligenceNotEnabled): .off
            case .unavailable(.modelNotReady): .downloading
            case .unavailable: .other
            }
        }

        var message: String {
            switch self {
            case .notEligible: "Catching up needs Apple Intelligence, which this device can't run."
            case .off: "Catching up needs Apple Intelligence. Turn it on in Settings, under Apple Intelligence & Siri."
            case .downloading: "Apple Intelligence is still getting ready. Try again once it has downloaded."
            case .other: "Apple Intelligence isn't available right now."
            }
        }
    }

    /// The session a summary is about.
    struct Subject: Sendable {
        let name: String
        /// "the Mac" or "the server".
        let host: String
        let folder: String
    }

    struct Summary: Sendable {
        let text: String
        let linesRead: Int
        let contextSize: Int
    }

    /// The session's last 200 lines and its screen, with lines the terminal wrapped joined back into one.
    static func history(of session: String) -> String {
        Tmux.prelude + "tmux capture-pane -p -J -S -200 -t \(Tmux.quote("=" + session + ":"))"
    }

    /// The last 200 lines with words in `capture`.
    static func excerpt(_ capture: String) -> [String] {
        Array(capture.split(separator: "\n", omittingEmptySubsequences: false).compactMap(Tmux.words(in:)).suffix(200))
    }

    /// Told to say only what the lines show: asked what a session "needs", the model made up next steps,
    /// once an `rm -rf` of the folder a sync had just copied.
    private static let instructions = """
        Someone stepped away from a terminal session. From its last lines of output, tell them in at most \
        three short, plain sentences what ran and how it ended. If it failed, say what failed. If it is \
        waiting for an answer, say what it asks them. Otherwise say it needs nothing from them. Only state \
        what the lines show: never tell them what to do next, never suggest a command, and never ask a \
        question. Speak to them as "you". Write no lists, headings, markdown or quotes.
        """

    /// The longest reply, in tokens.
    private static let replyTokens = 160

    /// Has the on-device model sum up `lines`, as many of the newest as fit its context.
    static func summarize(_ lines: [String], about subject: Subject) async throws -> Summary {
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        // Terminal text runs to about three characters a token.
        let room = (model.contextSize - replyTokens - 400) * 3
        var kept = lines[...]
        var characters = kept.reduce(0) { $0 + $1.count + 1 }
        while characters > room, kept.count > 1 {
            characters -= kept.removeFirst().count + 1
        }
        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(
            to: prompt(kept, about: subject),
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: replyTokens)
        )
        return Summary(text: tidy(response.content), linesRead: kept.count, contextSize: model.contextSize)
    }

    private static func prompt(_ lines: ArraySlice<String>, about subject: Subject) -> String {
        var about = "The session \"\(subject.name)\" on \(subject.host)"
        if !subject.folder.isEmpty { about += " in \(subject.folder)" }
        return about + ".\nIts last \(lines.count) lines of output, oldest first:\n" + lines.joined(separator: "\n")
    }

    /// The reply as at most three sentences of plain text, each starting with a capital, without the
    /// markdown the model sometimes adds.
    static func tidy(_ reply: String) -> String {
        let plain = reply
            .replacing("**", with: "")
            .replacing("`", with: "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingPrefix(#/\s*(?:[-*•#>]+|\d+[.)])\s+/#).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            // The model often starts a sentence in lowercase, which the sentence breaks below would not count
            // as a new sentence.
            .replacing(#/(^|[.!?]\s+)(\p{Ll})/#) { String($0.output.1) + $0.output.2.uppercased() }
        var sentences: [String] = []
        plain.enumerateSubstrings(in: plain.startIndex..., options: .bySentences) { sentence, _, _, stop in
            if let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty {
                sentences.append(sentence)
            }
            stop = sentences.count == 3
        }
        return sentences.isEmpty ? plain : sentences.joined(separator: " ")
    }

    /// A failed summary, in plain words.
    static func message(for error: any Error) -> String {
        let busy = "Apple Intelligence is busy. Try again in a moment."
        let refused = "Apple Intelligence wouldn't sum up what's on this screen."
        let language = "Apple Intelligence can't read the language on this screen."
        let downloading = Unavailable.downloading.message
        if #available(iOS 27.0, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .rateLimited: return busy
                case .guardrailViolation, .refusal: return refused
                case .unsupportedLanguageOrLocale: return language
                case .timeout: return "Apple Intelligence took too long. Try again."
                case .contextSizeExceeded: return "Its last lines were too long to sum up."
                case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide: break
                @unknown default: break
                }
            }
            if error is SystemLanguageModel.Error { return downloading }
            if let error = error as? LanguageModelSession.Error, error == .concurrentRequests { return busy }
        } else if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .rateLimited, .concurrentRequests: return busy
            case .guardrailViolation, .refusal: return refused
            case .unsupportedLanguageOrLocale: return language
            case .assetsUnavailable: return downloading
            case .exceededContextWindowSize: return "Its last lines were too long to sum up."
            case .unsupportedGuide, .decodingFailure: break
            @unknown default: break
            }
        }
        return "Apple Intelligence couldn't write a summary: \(error.localizedDescription)"
    }
}
