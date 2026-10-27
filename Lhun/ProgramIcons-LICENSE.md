# Artwork and fonts

## Program and model glyphs

`ProgramIcon.swift` requests [SF Symbols](https://developer.apple.com/sf-symbols/) through Apple's `Image(systemName:)` API. The source does not bundle symbol artwork, third-party program/model logos or pixel characters. The chosen glyphs are interface cues, not the named projects' logos. Program and model names identify what a session runs; they do not imply endorsement.

System fonts such as SF Mono and Menlo are also requested through Apple's APIs, not copied into this repository.

## Application icon

`LhunApp/AppIcon.icon/Assets/wave.svg` and its Icon Composer configuration are produced by this project's `tools/make-icon.swift`. The generator constructs the wave from geometric curves and a varying-width brush stroke. The shipped SVG has one path and no external image source.

The generator's optional comparison-sheet command reads neighboring application icons from the local operating system. Those icons and generated comparison sheets are not included in this source snapshot.

## Bundled fonts

All 20 `Fonts/*.otf` files are unchanged official files from GitHub's [Monaspace 1.400 release tree](https://github.com/githubnext/monaspace/tree/v1.400/fonts): Argon, Krypton, Neon, Radon and Xenon NF, each in Regular, Bold, Italic and Bold Italic. Their Git blob hashes match the corresponding upstream files. `Fonts/OFL.txt` matches that release's `LICENSE`.

The copyright, reserved font names and full SIL Open Font License 1.1 grant are retained in [Fonts/OFL.txt](Fonts/OFL.txt). Keep that file with redistributed fonts. The fonts may not be sold by themselves or relicensed as owner-authored code. The license does not grant trademark rights in embedded company glyphs.

No general license for Lhûn's original code or original application artwork has been selected. Third-party dependency licenses remain with their upstream packages; no dependency source or signed application binary is bundled here.

