import Testing
import UIKit
@testable import LhunKit


@Test("Process aliases and versions keep the same program recognition", arguments: [
    ("python3.12", "python"),
    ("node22", "node"),
    ("sqlite3", "sqlite"),
    ("/opt/homebrew/bin/nvim", "nvim"),
    ("Python3", "python"),
    ("2.1.112", "claude"),
    ("claude-code", "claude"),
    ("codex-aarch64-ap", "codex"),
    ("cursor-agent", "cursor"),
    ("npx", "npm"),
    ("pnpx", "pnpm"),
    ("bunx", "bun"),
    ("pip", "python"),
    ("ipython", "python"),
    ("uvx", "uv"),
    ("irb", "ruby"),
    ("gem", "ruby"),
    ("bundle", "ruby"),
    ("rustc", "cargo"),
    ("rustup", "cargo"),
    ("swiftc", "swift"),
    ("xcrun", "xcodebuild"),
    ("lazygit", "git"),
    ("tig", "git"),
    ("lazydocker", "docker"),
    ("k9s", "kubectl"),
    ("postgres", "psql"),
    ("redis-cli", "redis"),
    ("vi", "vim"),
    ("emacs-29.1", "emacs"),
    ("emacsclient", "emacs"),
    ("hx", "helix"),
    ("mosh", "ssh"),
    ("gmake", "make"),
    ("btop", "htop"),
    ("top", "htop"),
    ("man", "less"),
    ("more", "less"),
])
func programAliases(command: String, canonical: String) {
    #expect(ProgramIcon.forCommand(command) == ProgramIcon.forCommand(canonical))
    #expect(ProgramIcon.forCommand(command) != ProgramIcon.forCommand(""))
}

@Test("Shells and unknown commands remain terminals", arguments: ["-zsh", "/bin/bash", "sh", "frobnicate", ""])
func terminalFallback(command: String) {
    #expect(ProgramIcon.forCommand(command) == .symbol("terminal"))
}

@Test("A model id names its family", arguments: [
    ("anthropic/claude-opus-5-5", "claude"),
    ("amazon-bedrock/global.anthropic.claude-opus-5-5", "claude"),
    ("anthropic/a-model-named-later", "claude"),
    // The model's own name counts before a provider that names another family.
    ("google-vertex-anthropic/claude-opus-4", "claude"),
    ("openai-codex/gpt-6-sol", "openai"),
    ("openai-codex/gpt-5.6-luna", "openai"),
    ("openrouter/openai/o3-mini", "openai"),
    ("openrouter/google/gemini-2.5-pro", "gemini"),
    ("openrouter/~x-ai/grok-latest", "grok"),
    ("amazon-bedrock/global.xai.grok-4.7", "grok"),
    ("ollama/llama3.3", nil),
    ("", nil),
] as [(String, String?)])
func modelFamily(model: String, expected: String?) {
    #expect(ProgramIcon.family(ofModel: model) == expected)
}

@Test("omp keeps the reported model family", arguments: [
    ("anthropic/claude-opus-5-5", "claude"),
    ("openai-codex/gpt-6-sol", "openai"),
    ("openrouter/google/gemini-2.5-pro", "gemini"),
    ("xai/grok-4", "grok"),
    ("ollama/llama3.3", nil),
    ("", nil),
] as [(String, String?)])
func programIconForModel(model: String, family: String?) {
    #expect(ProgramIcon.forCommand("omp", model: model) == .omp(family: family))
}

@Test("A previous model cannot change the next program's icon", arguments: [
    "-zsh", "2.1.112", "codex", "python3.12", "gemini",
])
func staleModelDoesNotChangeProgram(command: String) {
    #expect(ProgramIcon.forCommand(command, model: "anthropic/claude-opus-5-5") == ProgramIcon.forCommand(command))
}

@MainActor
@Test("Recognized programs have a native glyph available on the device", arguments: [
    "claude", "codex", "gemini", "opencode", "amp", "aider", "cursor", "pi", "herdr", "akyl",
    "node", "npm", "pnpm", "yarn", "bun", "deno", "python", "uv", "ruby", "cargo", "go", "swift",
    "xcodebuild", "git", "gh", "docker", "kubectl", "terraform", "psql", "redis", "sqlite", "nvim",
    "vim", "emacs", "helix", "brew", "tailscale", "ssh", "make", "htop", "less",
])
func nativeProgramGlyph(command: String) {
    guard case let .symbol(name) = ProgramIcon.forCommand(command) else {
        Issue.record("A recognized program lost its native glyph.")
        return
    }
    #expect(name != "terminal")
    #expect(UIImage(systemName: name) != nil)
}

func rgba(_ image: CGImage) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try pixels.withUnsafeMutableBytes { bytes in
        let context = try #require(CGContext(
            data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return pixels
}

