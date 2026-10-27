import LhunKit
import SwiftUI

/// The Lhûn app: LhunKit's terminal space alone in its window.
@main
struct LhunApp: App {
    @State private var lhun = Lhun()

    var body: some Scene {
        WindowGroup {
            TerminalSpace(lhun)
                .lhunWindowAppearance()
                .onOpenURL { _ = lhun.handle($0) }
        }
        .commands {
            LhunCommands(lhun)
        }
    }
}
