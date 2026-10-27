import Foundation

/// A folder on a host as the path picker sees it, from one listing: what is in it, and every file below
/// it to search.
struct PathListing: Sendable {
    /// Absolute, as the host spells it.
    let folder: String
    /// The host's home folder.
    let home: String
    /// The folder's own entries: folders first, named with a trailing "/", then files; hidden ones after
    /// the rest of their group.
    let entries: [String]
    /// Every file below the folder and every folder on the way to one, relative to it and sorted; folders
    /// end in "/". In a git work tree these are git's files, so ignored ones stay out. Empty for a listing
    /// made without files.
    let paths: [String]
    /// True when the folder held more files than one listing takes.
    let isCapped: Bool

    /// Entries taken from one folder.
    static let entryCap = 5_000
    /// Files taken from one listing; past this, typing more of a name still finds most things.
    static let fileCap = 20_000

    /// Reads the output of `Tmux.listing`: the folder, the home folder, the folder's entries as `ls -p`
    /// names them, a line holding only "/" (no entry can be named that), then the files.
    init?(output: String) {
        let lines = output.split(separator: "\n")
        guard lines.count >= 3, let separator = lines[2...].firstIndex(of: "/") else { return nil }
        folder = String(lines[0])
        home = String(lines[1])
        entries = Self.sorted(lines[2..<separator].filter { $0 != ".git/" })
        let files = lines[(separator + 1)...]
        isCapped = files.count >= Self.fileCap
        paths = Self.withFolders(files)
    }

    /// The entries that are folders.
    var folders: [String] {
        entries.filter { $0.hasSuffix("/") }
    }

    /// How a picked path reads at the prompt: from the pane's folder when it is inside it, from "~" when
    /// it is inside the home folder, otherwise absolute. `paneFolder` is nil until the pane's own folder
    /// is known, and then only the last two apply.
    static func spelling(of path: String, from paneFolder: String?, home: String) -> String {
        if let paneFolder, let inside = relative(path, to: paneFolder) { return inside }
        if !home.isEmpty, let inside = relative(path, to: home) { return "~/" + inside }
        return path
    }

    /// A folder's name for a heading: "~" for home, from "~" inside it, otherwise absolute.
    static func name(of folder: String, home: String) -> String {
        folder == home ? "~" : spelling(of: folder, from: nil, home: home)
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    static func parent(of folder: String) -> String {
        guard let slash = folder.lastIndex(of: "/"), slash != folder.startIndex else { return "/" }
        return String(folder[..<slash])
    }

    /// The folder a typed path names, walked one name at a time: from the root when it starts with "/",
    /// from home when it starts with "~/", otherwise from `base`. "." stays, ".." goes up, and a name goes
    /// into the subfolder that best matches it, or else into the name as typed. `subfolders` gives a
    /// folder's subfolders, named with a trailing "/", or nil while they are not known; the walk stops at
    /// that folder, unfinished.
    static func walk(
        _ typed: Substring, from base: String, home: String, subfolders: (String) -> [String]?
    ) -> (folder: String, finished: Bool) {
        var folder = base
        var names = typed
        if names.hasPrefix("/") {
            folder = "/"
        } else if names.hasPrefix("~/") {
            folder = home
            names = names.dropFirst()
        }
        for name in names.split(separator: "/") {
            switch name {
            case ".":
                continue
            case "..":
                folder = parent(of: folder)
            default:
                guard let candidates = subfolders(folder) else { return (folder, false) }
                let best = FuzzyMatch.rank(FuzzyQuery(String(name)), in: candidates).first.map { candidates[$0].dropLast() }
                folder = join(folder, String(best ?? name))
            }
        }
        return (folder, true)
    }

    private static func relative(_ path: String, to folder: String) -> String? {
        let base = folder.hasSuffix("/") ? folder : folder + "/"
        guard path.hasPrefix(base), path.count > base.count else { return nil }
        return String(path.dropFirst(base.count))
    }

    private static func sorted(_ names: [Substring]) -> [String] {
        names.map(String.init).sorted { a, b in
            let (aFolder, bFolder) = (a.hasSuffix("/"), b.hasSuffix("/"))
            if aFolder != bFolder { return aFolder }
            let (aHidden, bHidden) = (a.hasPrefix("."), b.hasPrefix("."))
            if aHidden != bHidden { return bHidden }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// The files, plus each folder that holds one, so a search can land on a folder too.
    private static func withFolders(_ files: ArraySlice<Substring>) -> [String] {
        var folders = Set<Substring>()
        for file in files {
            var slash = file.firstIndex(of: "/")
            while let index = slash {
                folders.insert(file[...index])
                slash = file[file.index(after: index)...].firstIndex(of: "/")
            }
        }
        return (files.map(String.init) + folders.map(String.init)).sorted()
    }
}

extension Tmux {
    /// Where a listing starts.
    enum ListingStart {
        /// The folder the session's active pane is in.
        case pane(String)
        case folder(String)
        case home
    }

    /// Lists a folder for `PathListing(output:)`. With `files`, the listing also takes every file below
    /// the folder: git's files in a work tree (ignored ones left out), else fd's, else find's to a fixed
    /// depth with hidden folders and node_modules skipped.
    static func listing(_ start: ListingStart, files: Bool) -> String {
        let enter = switch start {
        case .pane(let session):
            #"d=$(tmux display-message -p -t \#(quote("=" + session + ":")) '#{pane_current_path}') && [ -n "$d" ] && cd "$d" || exit 3; "#
        case .folder(let folder):
            "cd \(quote(folder)) || exit 3; "
        case .home:
            #"cd "$HOME" || exit 3; "#
        }
        let entries = #"pwd; printf '%s\n' "$HOME"; command ls -1pAL 2>/dev/null | head -n \#(PathListing.entryCap); echo /"#
        guard files else { return prelude + enter + entries }
        return prelude + enter + entries + #"""
        ; { if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git ls-files -z -co --exclude-standard | tr '\0' '\n'; \
        elif command -v fd >/dev/null 2>&1; then fd --type f --max-depth 8 --color never; \
        else find . -maxdepth 8 \( -name '.?*' -o -name node_modules \) -prune -o -type f -print; fi; } 2>/dev/null \
        | sed 's|^\./||' | head -n \#(PathListing.fileCap)
        """#
    }

    /// Starts session `name` in `folder`, an absolute path.
    static func create(_ name: String, in folder: String) -> String {
        prelude + "tmux new-session -d -s \(quote(name)) -c \(quote(folder))"
    }

    /// A path as one shell word, the way a person would type it: bare when every character is plainly
    /// safe, single-quoted otherwise. A leading "~/" stays outside the quotes so the shell still expands
    /// it, and a relative path that starts with "-" gets "./" so no command takes it for an option.
    static func word(_ path: String) -> String {
        if path == "~" { return path }
        if path.hasPrefix("~/") { return "~/" + bare(String(path.dropFirst(2))) }
        if path.hasPrefix("-") { return bare("./" + path) }
        return bare(path)
    }

    /// Letters, digits and the punctuation no shell treats specially anywhere in a word. "=" and "~" are
    /// left out: zsh expands a word that starts with "=", and "~" mid-word is a pattern with EXTENDED_GLOB.
    private static func bare(_ text: String) -> String {
        let isSafe = text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "@%+:,./_-".unicodeScalars.contains(scalar))
        }
        return isSafe ? text : quote(text)
    }
}
