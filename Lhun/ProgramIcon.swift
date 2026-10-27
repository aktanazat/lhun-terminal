import SwiftUI

enum ProgramIcon: Equatable, Sendable {
    case symbol(String)
    case omp(family: String?)

    static func forCommand(_ command: String, model: String = "") -> ProgramIcon {
        var name = command.trimmingCharacters(in: .whitespaces).lowercased()
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        // A login shell's process is named "-zsh".
        name = String(name.drop { $0 == "-" })
        // Claude Code retitles its process to its version, so tmux reports "2.1.112" rather than "claude".
        if name.wholeMatch(of: /\d+(\.\d+)+/) != nil {
            name = "claude"
        }
        // "codex-aarch64-apple-darwin", "redis-cli" and "docker-compose" fall back to their first word.
        let firstWord = name.split(separator: "-").first.map(String.init) ?? name
        return lookup(name, model) ?? lookup(firstWord, model) ?? terminal
    }

    /// The family of a model a program reports, as "provider/model" or with more path in front:
    /// "claude", "openai", "gemini" or "grok", and nil for any other. Words of the model's own name, read
    /// from the end, count before its provider's, so a Claude reached through Bedrock or OpenRouter is
    /// still a Claude.
    static func family(ofModel model: String) -> String? {
        let words = model.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.reversed().lazy.compactMap(family(ofWord:)).first
    }

    private static func family(ofWord word: Substring) -> String? {
        if ["claude", "opus", "sonnet", "haiku", "fable", "anthropic"].contains(word) { return "claude" }
        // OpenAI's o-series, and the codenames omp's Codex models carry.
        if word.hasPrefix("gpt") || word.wholeMatch(of: /o\d+/) != nil
            || ["openai", "chatgpt", "codex", "sol", "astra", "luna", "terra"].contains(word) {
            return "openai"
        }
        if word.hasPrefix("gemini") || word == "google" { return "gemini" }
        if word.hasPrefix("grok") || word == "xai" { return "grok" }
        return nil
    }

    fileprivate static func symbol(forFamily family: String?) -> String {
        switch family {
        case "claude": "text.bubble"
        case "openai": "curlybraces"
        case "gemini": "lightbulb"
        case "grok": "binoculars"
        default: "pi"
        }
    }

    private static let terminal = ProgramIcon.symbol("terminal")

    private static func lookup(_ name: String, _ model: String) -> ProgramIcon? {
        let base = name.replacing(/[-_]?\d[\d.]*$/, with: "")
        let program = base.isEmpty ? name : base
        if program == "omp" { return .omp(family: family(ofModel: model)) }
        return table[program]
    }

    private static let table: [String: ProgramIcon] = {
        var table: [String: ProgramIcon] = [:]
        func symbol(_ symbol: String, _ names: String...) {
            for name in names { table[name] = .symbol(symbol) }
        }

        symbol(ProgramIcon.symbol(forFamily: "claude"), "claude")
        symbol(ProgramIcon.symbol(forFamily: "openai"), "codex")
        symbol(ProgramIcon.symbol(forFamily: "gemini"), "gemini")
        symbol("chevron.left.forwardslash.chevron.right", "opencode")
        symbol("bolt", "amp")
        symbol("person.2", "aider")
        symbol("cursorarrow.rays", "cursor-agent", "cursor")
        symbol("pi", "pi")
        symbol("square.grid.2x2", "herdr")
        symbol("brain.head.profile", "akyl")

        symbol("server.rack", "node")
        symbol("shippingbox", "npm", "npx")
        symbol("square.stack.3d.up", "pnpm", "pnpx")
        symbol("link", "yarn")
        symbol("hare", "bun", "bunx")
        symbol("leaf", "deno")
        symbol("function", "python", "pip", "ipython")
        symbol("bolt.horizontal", "uv", "uvx")
        symbol("number.square", "ruby", "irb", "gem", "bundle")
        symbol("wrench.and.screwdriver", "cargo", "rustc", "rustup")
        symbol("arrow.right", "go")
        symbol("speedometer", "swift", "swiftc")
        symbol("hammer.circle", "xcodebuild", "xcrun")
        symbol("arrow.triangle.branch", "git", "lazygit", "tig")
        symbol("tray.full", "gh")
        symbol("cube", "docker", "lazydocker")
        symbol("cube.transparent", "kubectl", "k9s")
        symbol("square.3.layers.3d", "terraform")
        symbol("externaldrive", "psql", "postgres")
        symbol("memorychip", "redis")
        symbol("cylinder", "sqlite")
        symbol("square.and.pencil", "nvim")
        symbol("pencil", "vim", "vi")
        symbol("text.cursor", "emacs", "emacsclient")
        symbol("text.alignleft", "hx", "helix")
        symbol("arrow.down.circle", "brew")
        symbol("point.3.connected.trianglepath.dotted", "tailscale")
        symbol("network", "ssh", "mosh")
        symbol("hammer", "make", "gmake")

        // Monitors and pagers.
        symbol("gauge.with.dots.needle.33percent", "htop", "btop", "top")
        symbol("doc.text", "less", "man", "more")
        return table
    }()
}

struct ProgramIconView: View {
    let command: String
    var model = ""
    var size: CGFloat = 20

    var body: some View {
        Group {
            switch ProgramIcon.forCommand(command, model: model) {
            case .symbol(let name):
                Image(systemName: name).resizable().scaledToFit()
            case .omp(let family):
                OmpIcon(family: family, size: size)
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

private struct OmpIcon: View {
    let family: String?
    let size: CGFloat
    @Environment(\.displayScale) private var scale

    var body: some View {
        // Whole screen pixels, two at the least.
        let line = max(2, (size * scale / 14).rounded(.down)) / scale
        familyMark(lift: line)
            .overlay(alignment: .bottom) {
                Capsule().frame(width: (size * 0.6).rounded(), height: line)
            }
    }

    private func familyMark(lift: CGFloat) -> some View {
        let side = (size * 0.8).rounded()
        return Image(systemName: ProgramIcon.symbol(forFamily: family))
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
            .offset(y: -lift)
            .frame(width: size, height: size)
    }
}

private let previewCommands = [
    "claude", "codex", "gemini", "opencode", "amp", "aider", "cursor-agent", "omp", "pi", "herdr", "akyl",
    "node", "npm", "pnpm", "yarn", "bun", "deno", "python3.12", "uv", "ruby", "cargo", "go", "swift",
    "xcodebuild", "git", "gh", "docker", "kubectl", "terraform", "psql", "redis-cli", "sqlite3", "nvim", "vim",
    "emacs", "hx", "brew", "tailscale", "ssh", "make", "htop", "less", "-zsh",
]

private let previewModels = [
    "anthropic/claude-opus-5-5", "openai-codex/gpt-6-sol", "openrouter/google/gemini-2.5-pro", "xai/grok-4",
    "ollama/llama3.3",
]

private struct ProgramIconPreview: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.near) {
                ForEach(previewCommands, id: \.self) { command in
                    row(command)
                }
                ForEach(previewModels, id: \.self) { model in
                    row("omp", model: model)
                }
            }
            .padding(Metrics.inset)
        }
        .background(.background)
    }

    private func row(_ command: String, model: String = "") -> some View {
        HStack(spacing: Metrics.near) {
            ProgramIconView(command: command, model: model, size: 12)
            ProgramIconView(command: command, model: model, size: 16)
            ProgramIconView(command: command, model: model)
            Text([command, model].filter { !$0.isEmpty }.joined(separator: " "))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Program icons, light") {
    ProgramIconPreview().preferredColorScheme(.light)
}

#Preview("Program icons, dark") {
    ProgramIconPreview().preferredColorScheme(.dark)
}
