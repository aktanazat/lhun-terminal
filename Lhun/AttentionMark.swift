import AudioToolbox
import SwiftUI
import UIKit

/// The mark beside a session he has not seen since it finished or started to wait on him: one 8 pt
/// circle in the primary text color, the same for both, so it means only that something there is new to
/// him. A working session draws nothing, since working is the usual state, and the mark never moves.
/// VoiceOver and UI tests still read which of the three it is (`label`).
struct AttentionMark: View {
    let mark: AttentionBoard.Mark

    var body: some View {
        switch mark {
        case .working:
            EmptyView()
        case .finished, .needsYou:
            Circle()
                .fill(Color.primary)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        }
    }

    /// What VoiceOver and UI tests read.
    static func label(_ mark: AttentionBoard.Mark?) -> String {
        switch mark {
        case .working: "working"
        case .finished: "finished"
        case .needsYou: "needs you"
        case nil: ""
        }
    }

    /// The mark, then what the program behind it says, as in "needs you, question: Which branch?".
    static func label(_ mark: AttentionBoard.Mark?, status: ProgramStatus?) -> String {
        guard mark != nil, let words = words(status) else { return label(mark) }
        return "\(label(mark)), \(words)"
    }

    /// What a program's report adds to its mark: why it waits, or that it failed, then its message.
    static func words(_ status: ProgramStatus?) -> String? {
        guard let status else { return nil }
        var reason: String?
        switch status.state {
        case .blocked:
            switch status.kind {
            case .permission: reason = "approval"
            case .question: reason = "question"
            case .auth: reason = "sign-in"
            case nil: reason = nil
            }
        case .error: reason = "failed"
        case .done, .working, .idle, nil: reason = nil
        }
        let words = [reason, status.message].compactMap(\.self)
        return words.isEmpty ? nil : words.joined(separator: ": ")
    }
}

/// The iOS Glass text tone follows silent mode; no sound file is bundled.
@MainActor
enum Chime {
    private static let glass: SystemSoundID = 1009
    nonisolated static let spacing: Duration = .seconds(10)
    private static var lastPlayed: ContinuousClock.Instant?

    /// Returns whether it played.
    static func play() -> Bool {
        let now = ContinuousClock.now
        guard UIApplication.shared.applicationState == .active, isDue(at: now, after: lastPlayed) else { return false }
        AudioServicesPlaySystemSound(glass)
        lastPlayed = now
        return true
    }

    /// Whether a chime may play at `now`, the last having played at `last`.
    nonisolated static func isDue(at now: ContinuousClock.Instant, after last: ContinuousClock.Instant?) -> Bool {
        last.map { now - $0 >= spacing } ?? true
    }
}
