import Foundation
import NIOCore
import OSLog
import UniformTypeIdentifiers

/// Files sent to a host by pasting or dropping them on a terminal. Each one lands in a new folder of
/// its own under `~/.cache/lhun/uploads`, named for when it arrived, so names never collide and the
/// newest sort last. Nothing prunes the folder.
enum Upload {
    /// The largest file Lhûn sends.
    static let limit = 50 * 1024 * 1024

    private static let log = Logger(subsystem: "com.aktanazat.lhun", category: "upload")

    enum Failure: LocalizedError {
        case tooLarge(bytes: Int)
        case unreadable
        case noPath

        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                "That file is \((bytes + 1024 * 1024 - 1) / (1024 * 1024)) MB. Lhûn uploads files up to \(limit / (1024 * 1024)) MB."
            case .unreadable:
                "Lhûn couldn't read that file."
            case .noPath:
                "The host didn't say where it saved the file."
            }
        }
    }

    /// A file name safe in any shell and on any file system: letters, digits, dots, dashes and
    /// underscores, no leading dot, at most 120 bytes, extension kept.
    static func safeName(_ name: String) -> String {
        let dot = name.lastIndex(of: ".").flatMap { $0 > name.startIndex ? $0 : nil }
        let stem = clean(dot.map { String(name[..<$0]) } ?? name)
        let ext = clean(dot.map { String(name[name.index(after: $0)...]) } ?? "").filter { $0 != "." }
        var kept = stem.isEmpty ? "file" : stem
        let suffix = ext.isEmpty ? "" : "." + String(ext.prefix(16))
        while kept.utf8.count + suffix.utf8.count > 120, kept.count > 1 {
            kept.removeLast()
        }
        return kept + suffix
    }

    /// The command that saves its standard input as `name` in a new folder and prints the full path.
    static func command(saving name: String, at date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04ld%02ld%02ld-%02ld%02ld%02ld",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        return "umask 077; d=$(mkdir -p ~/.cache/lhun/uploads && mktemp -d ~/.cache/lhun/uploads/\(stamp)-XXXXXX)"
            + " && cat > \"$d/\(name)\" && printf '%s\\n' \"$d/\(name)\""
    }

    /// How long a file of this size may take: half a minute, plus a second for every 100 KB. Slower
    /// than that, the host is treated as gone.
    static func timeout(for bytes: Int) -> TimeAmount {
        .seconds(30 + Int64(bytes / 100_000))
    }

    /// What a paste sends: the items the clipboard holds in a form Lhûn sends, unless any of them is
    /// text, which pastes as text. A copied file's location comes with it as a link, which is not text.
    static func files(in providers: [NSItemProvider]) -> [NSItemProvider] {
        guard !providers.contains(where: { $0.registeredContentTypes.contains { $0.conforms(to: .text) } }) else { return [] }
        return providers.filter { format(of: $0) != nil }
    }

    /// The form of a pasted or dropped item that Lhûn sends: its first type of file data with a file
    /// name extension. That leaves out links, a copied file's location, and the in-memory forms some
    /// apps add first, such as UIKit's own form of a copied image.
    static func format(of provider: NSItemProvider) -> UTType? {
        provider.registeredContentTypes.first {
            $0.conforms(to: .data) && !$0.conforms(to: .url) && $0.preferredFilenameExtension != nil
        }
    }

    /// Reads one pasted or dropped item in its `format`, with the bytes as they are: an image is not
    /// re-encoded, so it arrives exactly as it left. It is asked for as a file, which every app can hand
    /// over, whether it put the bytes themselves on the clipboard or only a file. Items over the limit
    /// are refused before they are read.
    @MainActor
    static func read(_ provider: NSItemProvider) async throws -> (data: Data, name: String) {
        guard let format = format(of: provider) else { throw Failure.unreadable }
        let given = await givenName(of: provider)
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: format, openInPlace: false) { url, _, error in
                guard let url else {
                    log.error("No \(format.identifier, privacy: .public) file came: \(String(describing: error), privacy: .public)")
                    continuation.resume(throwing: Failure.unreadable)
                    return
                }
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= limit else { throw Failure.tooLarge(bytes: size) }
                    // Mapped, not copied: the file stays readable once the system deletes it after this.
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    continuation.resume(returning: (data, name(given, format: format)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The name an item came with: its own, or the name of the file it was copied from. An app that
    /// copies a file, rather than its bytes, puts the file's location beside it, and across apps the
    /// item itself arrives without a name.
    @MainActor
    private static func givenName(of provider: NSItemProvider) async -> String? {
        if let suggested = provider.suggestedName { return suggested }
        guard provider.registeredContentTypes.contains(where: { $0.conforms(to: .fileURL) }) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url?.lastPathComponent)
            }
        }
    }

    /// The item's name, with its type's extension when the name has none. An item without a name is
    /// called image or file.
    private static func name(_ given: String?, format: UTType) -> String {
        let suffix = format.preferredFilenameExtension.map { "." + $0 } ?? ""
        guard let given, !given.isEmpty else { return (format.conforms(to: .image) ? "image" : "file") + suffix }
        return (given as NSString).pathExtension.isEmpty ? given + suffix : given
    }

    /// Letters, digits, dots and underscores stay; every other run of characters becomes one dash.
    /// Dots and dashes at either end go.
    private static func clean(_ text: String) -> String {
        var cleaned = ""
        for character in text {
            if character.isLetter || character.isNumber || character == "." || character == "_" {
                cleaned.append(character)
            } else if cleaned.last != "-" {
                cleaned.append("-")
            }
        }
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    }
}

extension SSHConnection {
    /// Saves `data` on the host as a new file named after `name`, and returns its absolute path.
    /// Anything over `Upload.limit` is refused before a byte is sent.
    func upload(_ data: Data, named name: String) async throws -> String {
        guard data.count <= Upload.limit else { throw Upload.Failure.tooLarge(bytes: data.count) }
        let command = Upload.command(saving: Upload.safeName(name), at: .now)
        let output = try await run(command, input: data, timeout: Upload.timeout(for: data.count))
        guard let path = output.split(whereSeparator: \.isNewline).last.map(String.init), path.hasPrefix("/") else {
            throw Upload.Failure.noPath
        }
        return path
    }
}
