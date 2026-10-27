import CoreText
import UIKit

/// The terminal's typeface, chosen from the palette's Font… list and remembered. Monaspace Xenon, the face
/// the Mac's Ghostty uses, is the default and the only one carrying the Nerd Font icons: every other face
/// draws those icons from Xenon through a Core Text cascade, so prompts and file icons still show.
enum TerminalFont: String, CaseIterable, Identifiable, Sendable {
    case xenon, neon, argon, krypton, radon, sfMono, menlo

    static let defaultsKey = "terminalFont"

    /// The remembered choice, for code that has no terminal at hand.
    static var chosen: TerminalFont {
        LhunDefaults.shared.string(forKey: defaultsKey).flatMap(TerminalFont.init(rawValue:)) ?? .xenon
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xenon: "Monaspace Xenon"
        case .neon: "Monaspace Neon"
        case .argon: "Monaspace Argon"
        case .krypton: "Monaspace Krypton"
        case .radon: "Monaspace Radon"
        case .sfMono: "SF Mono"
        case .menlo: "Menlo"
        }
    }

    /// The name the Font… row shows on its right.
    var shortTitle: String {
        switch self {
        case .xenon: "Xenon"
        case .neon: "Neon"
        case .argon: "Argon"
        case .krypton: "Krypton"
        case .radon: "Radon"
        case .sfMono: "SF Mono"
        case .menlo: "Menlo"
        }
    }

    enum Style: String, CaseIterable, Sendable {
        case regular = "Regular", bold = "Bold", italic = "Italic", boldItalic = "BoldItalic"

        var isBold: Bool { self == .bold || self == .boldItalic }
        var isItalic: Bool { self == .italic || self == .boldItalic }
    }

    /// One style of the face at `size`, with Xenon's same style behind it for the glyphs it lacks.
    func font(_ style: Style, size: CGFloat) -> CTFont {
        BundledFonts.register()
        let xenon = "MonaspaceXenonNF-\(style.rawValue)"
        let fallback = CTFontDescriptorCreateWithNameAndSize(xenon as CFString, size)
        let base: CTFont
        switch self {
        case .xenon:
            return Self.bundled(xenon, size: size)
        case .neon, .argon, .krypton, .radon:
            base = Self.bundled("Monaspace\(shortTitle)-\(style.rawValue)", size: size)
        case .menlo:
            base = Self.bundled("Menlo-\(style.rawValue)", size: size)
        case .sfMono:
            let upright = UIFont.monospacedSystemFont(ofSize: size, weight: style.isBold ? .bold : .regular) as CTFont
            let system = style.isItalic
                ? CTFontCreateCopyWithSymbolicTraits(upright, size, nil, .traitItalic, .traitItalic) ?? upright
                : upright
            // A Core Text line ignores the cascade list of a system UI font and falls to LastResort, so the
            // same outlines are taken again as a plain font, its weight kept through the variation.
            var attributes: [CFString: Any] = [kCTFontCascadeListAttribute: [fallback]]
            if let variation = CTFontCopyVariation(system) {
                attributes[kCTFontVariationAttribute] = variation
            }
            return CTFontCreateWithGraphicsFont(
                CTFontCopyGraphicsFont(system, nil), size, nil,
                CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
            )
        }
        let cascade = [kCTFontCascadeListAttribute: [fallback]] as CFDictionary
        return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), cascade), size, nil)
    }

    /// A face LhunKit ships (`BundledFonts`) or iPadOS carries, by PostScript name. Core Text quietly
    /// substitutes another face for a missing one, so the name it found is checked.
    private static func bundled(_ name: String, size: CGFloat) -> CTFont {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        guard CTFontCopyPostScriptName(font) as String == name else {
            fatalError("\(name) is missing from LhunKit's Fonts folder")
        }
        return font
    }
}

/// The Monaspace faces in LhunKit's Fonts folder, registered for this process the first time any font is
/// asked for, so neither the Lhûn app nor an app embedding LhunKit lists them in its Info.plist. Every
/// lookup of a shipped face calls `register()` first; `Lhun` calls it as it is made, ahead of the first
/// frame.
enum BundledFonts {
    /// Registers every face, the first time only; later calls return at once.
    static func register() {
        _ = registered
    }

    /// Each face synchronously, before the first lookup returns. A face already registered, as by an app
    /// that ships the same file, stays as it was.
    private static let registered: Void = {
        for url in Bundle.module.urls(forResourcesWithExtension: "otf", subdirectory: "Fonts") ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}
