/// What a paste types, made safe as xterm and Ghostty make theirs (Ghostty's CVE-2026-26982). Text
/// copied from a web page or a chat can carry bytes a program reads as keys: Esc, which could end a
/// bracketed paste early and type the rest as commands, or the line-editing controls such as Ctrl+C
/// and Ctrl+U. Each of those becomes a space. A program that takes pastes as one piece (bracketed
/// paste, which shells and agents turn on) gets the text framed; one that does not gets each line ended
/// with a Return, as a terminal types it, so each line runs as it arrives, and text that `breaksLines`
/// waits for him to say so first (AppModel.paste).
enum Paste {
    private static let start = Array("\u{1B}[200~".utf8)
    private static let end = Array("\u{1B}[201~".utf8)

    /// The bytes to send for `text`.
    static func bytes(_ text: String, bracketed: Bool) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count + (bracketed ? start.count + end.count : 0))
        if bracketed { bytes += start }
        for byte in text.utf8 {
            switch byte {
            // xterm's list, as Ghostty copies it: NUL, EOT, ENQ, BS, ESC, DEL, and the keys a terminal's
            // line discipline acts on: Ctrl+C, \, U, Z, Q, S, W, V, R, O.
            case 0x00, 0x04, 0x05, 0x08, 0x1B, 0x7F,
                 0x03, 0x1C, 0x15, 0x1A, 0x11, 0x13, 0x17, 0x16, 0x12, 0x0F:
                bytes.append(0x20)
            case 0x0A where !bracketed:
                bytes.append(0x0D)
            default:
                bytes.append(byte)
            }
        }
        if bracketed { bytes += end }
        return bytes
    }

    /// Whether the text holds a line break, which a program reading keys takes as Return and runs.
    static func breaksLines(_ text: String) -> Bool {
        text.utf8.contains { $0 == 0x0A || $0 == 0x0D }
    }

    /// How many lines `text` runs as, for asking.
    static func lines(_ text: String) -> Int {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).count
    }
}
