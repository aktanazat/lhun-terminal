import CoreText
@testable import LhunKit
import Foundation
import Testing

/// Laid out as the terminal lays out a cell, through a Core Text line. Every face has powerline arrows of
/// its own; the folder icon is one only Xenon NF has, so Xenon draws both in one run.
@Test("Every face draws its own letters, and the Nerd Font icons from Xenon NF in the same style",
      arguments: TerminalFont.allCases)
func faceDrawsIconsFromXenon(face: TerminalFont) {
    for style in TerminalFont.Style.allCases {
        let font = face.font(style, size: 14)
        let own = CTFontCopyPostScriptName(font) as String
        let xenon = "MonaspaceXenonNF-\(style.rawValue)"
        #expect(drawing("M\u{F07B}", with: font) == (face == .xenon ? [xenon] : [own, xenon]), "\(face) \(style)")
    }
}

/// The PostScript names of the faces each run of `text` is drawn with, starting from `font`.
private func drawing(_ text: String, with font: CTFont) -> [String] {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    return (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).map { run in
        let attributes = CTRunGetAttributes(run) as NSDictionary
        // A run always carries the font it was laid out in.
        return CTFontCopyPostScriptName(attributes[kCTFontAttributeName] as! CTFont) as String
    }
}
