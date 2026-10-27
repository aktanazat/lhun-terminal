import Testing
@testable import LhunKit

private let start = Array("\u{1B}[200~".utf8)
private let end = Array("\u{1B}[201~".utf8)

@Test("Pasted text can't end a bracketed paste early and type the rest as keys")
func pasteKeepsItsFrame() {
    let bytes = Paste.bytes("echo hi\u{1B}[201~rm -rf ~\n", bracketed: true)
    #expect(bytes == start + Array("echo hi [201~rm -rf ~\n".utf8) + end)
}

@Test("The keys a terminal's line editing acts on become spaces, in either mode", arguments: [true, false])
func pasteDisarmsControls(bracketed: Bool) {
    // Ctrl+C, Ctrl+U, Ctrl+W, Ctrl+Z, Ctrl+\, Ctrl+V, Ctrl+R, Ctrl+O, Ctrl+Q, Ctrl+S, NUL, EOT, ENQ, BS, DEL.
    let controls = "\u{03}\u{15}\u{17}\u{1A}\u{1C}\u{16}\u{12}\u{0F}\u{11}\u{13}\u{00}\u{04}\u{05}\u{08}\u{7F}"
    let bytes = Paste.bytes("a" + controls + "b", bracketed: bracketed)
    let body = bracketed ? Array(bytes.dropFirst(start.count).dropLast(end.count)) : bytes
    #expect(body == Array("a".utf8) + Array(repeating: 0x20, count: controls.utf8.count) + Array("b".utf8))
}

@Test("Tabs, line breaks and every other character pass as they are into a bracketed paste")
func bracketedPasteKeepsText() {
    let text = "def f():\n\treturn \"é 日本 𝑥\"\r\n"
    #expect(Paste.bytes(text, bracketed: true) == start + Array(text.utf8) + end)
}

@Test("Without bracketed paste, each line ends with Return as a terminal types it")
func unbracketedPasteTypesReturns() {
    #expect(Paste.bytes("ls\npwd\r\n", bracketed: false) == Array("ls\rpwd\r\r".utf8))
}

@Test("Text with a line break in it, and only such text, would run as it lands", arguments: [
    ("ls\n", true),
    ("ls\rpwd", true),
    ("ls -la\tx", false),
    ("", false),
])
func pasteBreaksLines(text: String, breaks: Bool) {
    #expect(Paste.breaksLines(text) == breaks)
}
