import CryptoKit
import Foundation

/// Getting a file from the host: ⌘⇧O, or Get File in the palette, finds a file below the session's folder
/// in the path picker, copies it to the device and opens it in Quick Look, where Share sends it on. The
/// copy lives in the app's temporary folder only while the preview is open.
enum GetFile {
    /// The largest file Lhûn gets, the same as the largest it uploads.
    static let limit = Upload.limit

    /// Where the copy on show lives, in a folder of its own.
    static let folder = URL.temporaryDirectory.appending(path: "fetched", directoryHint: .isDirectory)

    enum Failure: LocalizedError {
        case tooLarge(bytes: Int)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                "That file is \((bytes + 1024 * 1024 - 1) / (1024 * 1024)) MB. Lhûn gets files up to \(limit / (1024 * 1024)) MB."
            }
        }
    }

    /// Prints the file at `path`, an absolute path. A file over the limit prints nothing and exits 3
    /// with its size as the error output; anything that is not a readable file exits 2.
    static func command(reading path: String) -> String {
        #"f=\#(Tmux.quote(path)); [ -f "$f" ] && [ -r "$f" ] || { echo "Lhûn can't read that file." >&2; exit 2; }; "#
            + #"n=$(wc -c < "$f" | tr -d ' '); [ "$n" -le \#(limit) ] || { echo "$n" >&2; exit 3; }; "#
            + #"exec head -c \#(limit + 1) "$f""#
    }

    /// Keeps `data` under `name` in a new folder, after throwing away any copy left from before.
    static func save(_ data: Data, named name: String) throws -> URL {
        discard()
        let place = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let file = place.appending(path: name, directoryHint: .notDirectory)
        try data.write(to: file, options: .completeFileProtection)
        return file
    }

    static func discard() {
        try? FileManager.default.removeItem(at: folder)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension SSHConnection {
    /// The bytes of the host's file at `path`. A file over `GetFile.limit` is refused before a byte of
    /// it comes.
    func download(_ path: String) async throws -> Data {
        let data: Data
        do {
            data = try await runForBytes(GetFile.command(reading: path), timeout: Upload.timeout(for: GetFile.limit))
        } catch SSHFailure.commandFailed(status: 3, message: let size) {
            throw GetFile.Failure.tooLarge(bytes: Int(size) ?? GetFile.limit + 1)
        }
        // The file grew past the limit after its size was read.
        guard data.count <= GetFile.limit else { throw GetFile.Failure.tooLarge(bytes: data.count) }
        return data
    }
}

extension AppModel {
    /// Copies the host's file at `path` to the device and opens it in Quick Look. It comes over a
    /// connection of its own, as uploads go, so redialing the session list when Lhûn comes back never
    /// cuts it off and typing never waits behind it. Only one file comes at a time.
    func getFile(_ path: String, on link: HostLink) {
        guard gettingFile == nil else { return }
        let name = (path as NSString).lastPathComponent
        gettingFile = name
        Task {
            defer { gettingFile = nil }
            do {
                let connection = try await link.openConnection()
                defer { connection.close() }
                let data = try await connection.download(path)
                let file = try GetFile.save(data, named: name)
                probe?.record("fetched", details: ["fetched": ["name": name, "bytes": data.count, "sha256": GetFile.sha256(data)]])
                fetched = file
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// The preview closed: its copy goes, and typing goes back to the terminal.
    func closeFetched() {
        guard fetched != nil else { return }
        fetched = nil
        GetFile.discard()
        probe?.record("preview closed")
        focusTerminal()
    }
}
