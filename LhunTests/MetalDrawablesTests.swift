import MetalKit
import Testing
import UIKit
@testable import LhunKit

/// What a terminal on screen holds to draw with. Each drawable its Metal layer keeps is a texture the size of
/// the terminal. The renderer draws one frame at a time, so two drawables hold the frame on screen and the
/// one being drawn; the third Core Animation keeps by default only lets a frame start before the last one
/// reached the screen. SwiftTerm's fork sets two (project.yml), and a SwiftTerm without that line fails here.
@MainActor
struct MetalDrawablesTests {
    @Test("A terminal drawing with Metal keeps two drawables, not three")
    func twoDrawables() throws {
        let view = LhunTerminalView(frame: CGRect(x: 0, y: 0, width: 1178, height: 259), options: TerminalModel.options)
        try view.setUseMetal(true)
        let metalView = try #require(view.subviews.lazy.compactMap { $0 as? MTKView }.first, "turning Metal on added no Metal view")
        let layer = try #require(metalView.layer as? CAMetalLayer)
        #expect(layer.maximumDrawableCount == 2)
    }
}
