import Foundation
import Testing
@testable import LhunKit

struct WorkspaceTests {
    static let a = SessionRef(host: "mac", name: "a")
    static let b = SessionRef(host: "mac", name: "b")
    static let c = SessionRef(host: "server", name: "c")
    static let d = SessionRef(host: "server", name: "d")
    static let e = SessionRef(host: "mac", name: "e")

    static func twoTabs() -> WorkspaceStore {
        var store = WorkspaceStore(selection: a)
        store.open(b, on: .right, over: a)
        store.selectMember(c)
        store.open(d, on: .bottom, over: c)
        return store
    }

    @Test("Each tab restores its own pair, orientation, last focus and zoom without replacing the other tab")
    func tabsKeepTheirTerminals() {
        var store = Self.twoTabs()
        store.toggleZoom(Self.d)
        store.selectTab(Self.a)
        #expect(store.panes == [Self.a, Self.b])
        #expect(store.selection == Self.b)
        #expect(!store.stacked)
        #expect(store.zoomed == nil)
        store.selectMember(Self.a)
        store.selectTab(Self.c)
        #expect(store.panes == [Self.c, Self.d])
        #expect(store.selection == Self.d)
        #expect(store.stacked)
        #expect(store.zoomed == Self.d)
        store.selectTab(Self.a)
        #expect(store.selection == Self.a)
    }

    @Test("Direct selection reveals the requested hidden terminal and keeps both members in their tab")
    func directSelectionTargetsTheMember() {
        var store = Self.twoTabs()
        store.toggleZoom(Self.d)
        store.selectTab(Self.a)
        store.selectMember(Self.c)
        #expect(store.selection == Self.c)
        #expect(store.panes == [Self.c, Self.d])
        #expect(store.zoomed == nil)
        #expect(store.tabMembers(Self.a) == [Self.a, Self.b])
    }

    @Test("Moving a split to the other side does not change its tab representative")
    func reorderingKeepsTheRoot() {
        var store = WorkspaceStore(selection: Self.a)
        store.open(Self.b, on: .left, over: Self.a)
        #expect(store.panes == [Self.b, Self.a])
        #expect(store.tabRoot(for: Self.b) == Self.a)
        store.open(Self.a, on: .top, over: Self.a)
        #expect(store.panes == [Self.a, Self.b])
        #expect(store.tabRoot(for: Self.b) == Self.a)
    }

    @Test("Splitting an occupied card keeps all three terminals in one tab")
    func nestedSplitKeepsEveryTerminal() {
        var store = WorkspaceStore(selection: Self.a)
        store.open(Self.b, on: .right, over: Self.a)
        store.open(Self.e, on: .bottom, over: Self.b)
        #expect(store.panes == [Self.a, Self.b, Self.e])
        #expect(store.tabMembers(Self.b) == [Self.a, Self.b, Self.e])
        #expect(store.layout?.nearestSplit(to: Self.e) == [1])
        store.selectMember(Self.b)
        #expect(store.selection == Self.b)
        store.remove([Self.b])
        #expect(store.panes == [Self.a, Self.e])
    }

    @Test("Dropping a terminal from another tab moves it once and preserves both remaining terminals")
    func movingBetweenTabsHasOneOwner() {
        var store = Self.twoTabs()
        store.open(Self.a, on: .right, over: Self.d)
        #expect(store.panes == [Self.c, Self.d, Self.a])
        #expect(store.tabRoot(for: Self.a) == Self.c)
        #expect(store.tabMembers(Self.b) == [Self.b])
        #expect(store.tabRoot(for: Self.b) == Self.b)
        #expect(store.tabMembers(Self.d) == [Self.c, Self.d, Self.a])
        #expect(store.groups.flatMap(\.members).filter { $0 == Self.a }.count == 1)
        #expect(Set(store.groups.flatMap(\.members)) == [Self.a, Self.b, Self.c, Self.d])
    }

    @Test("Removing an inactive root or member preserves the other tab and promotes its surviving terminal", arguments: [a, b])
    func offscreenRemovalPreservesTheOtherTab(_ removed: SessionRef) {
        var store = Self.twoTabs()
        let surviving = removed == Self.a ? Self.b : Self.a
        store.remove([removed])
        #expect(store.panes == [Self.c, Self.d])
        #expect(store.selection == Self.d)
        #expect(store.stacked)
        #expect(store.tabMembers(surviving) == [surviving])
        #expect(store.tabRoot(for: surviving) == surviving)
        store.selectTab(surviving)
        #expect(store.selection == surviving)
        #expect(!store.stacked)
        #expect(store.zoomed == nil)
    }

    @Test("Renaming an inactive root or member keeps group identity, focus and size without altering another tab", arguments: [a, b])
    func renameFollowsTheTerminal(_ old: SessionRef) throws {
        var store = Self.twoTabs()
        store.selectTab(Self.a)
        store.resize(to: 0.375)
        store.toggleZoom(Self.b)
        let groupID = try #require(store.activeID)
        store.selectTab(Self.c)
        store.rename(old, to: Self.e)
        #expect(store.panes == [Self.c, Self.d])
        #expect(store.selection == Self.d)
        let pair = [Self.a, Self.b].map { $0 == old ? Self.e : $0 }
        store.selectTab(Self.e)
        #expect(store.activeID == groupID)
        #expect(store.panes == pair)
        #expect(store.selection == (old == Self.b ? Self.e : Self.b))
        #expect(store.zoomed == (old == Self.b ? Self.e : Self.b))
        #expect(store.tabRoot(for: Self.e) == (old == Self.a ? Self.e : Self.a))
        #expect(store.shares.share(of: pair) == 0.375)
        #expect(!store.groups.flatMap(\.members).contains(old))
    }

    @Test("Closing a tab removes all of its members but does not close the other tab")
    func detachingATabPreservesOtherWork() {
        var store = Self.twoTabs()
        store.remove(Set(store.tabMembers(Self.a)))
        #expect(store.panes == [Self.c, Self.d])
        #expect(store.selection == Self.d)
        #expect(Set(store.groups.flatMap(\.members)) == [Self.c, Self.d])
        store.remove(Set(store.tabMembers(Self.c)))
        #expect(store.selection == nil)
        #expect(store.panes.isEmpty)
        #expect(store.groups.isEmpty)
    }

    @Test("A saved workspace restores every tab and each tab's focus, zoom, orientation and size")
    func persistenceRestoresAllTabs() throws {
        var store = Self.twoTabs()
        store.resize(to: 0.625)
        store.toggleZoom(Self.d)
        store.selectTab(Self.a)
        store.resize(to: 0.375)
        store.selectMember(Self.a)
        let data = try PropertyListEncoder().encode(store)
        var restored = try PropertyListDecoder().decode(WorkspaceStore.self, from: data)
        #expect(restored == store)
        restored.selectTab(Self.c)
        #expect(restored.panes == [Self.c, Self.d])
        #expect(restored.selection == Self.d)
        #expect(restored.zoomed == Self.d)
        #expect(restored.stacked)
        #expect(restored.shares.share(of: restored.panes) == 0.625)
        restored.selectTab(Self.a)
        #expect(restored.selection == Self.a)
        #expect(restored.shares.share(of: restored.panes) == 0.375)
    }

    @Test("A floating card returns to its exact nested split after a relaunch")
    func floatingReturnsToItsSplit() throws {
        var store = WorkspaceStore(selection: Self.a)
        store.open(Self.b, on: .right, over: Self.a)
        store.open(Self.e, on: .bottom, over: Self.b)
        let original = try #require(store.layout)
        store.toggleFloating(Self.e)
        #expect(store.layout?.members == [Self.a, Self.b])
        let data = try PropertyListEncoder().encode(store)
        var restored = try PropertyListDecoder().decode(WorkspaceStore.self, from: data)
        #expect(restored.isFloating(Self.e))
        restored.toggleFloating(Self.e)
        #expect(restored.layout == original)
    }

    @Test("Keyboard focus order stays fixed when a floating card is raised")
    func floatingFocusOrderDoesNotFollowStacking() {
        var store = WorkspaceStore(selection: Self.a)
        store.open(Self.b, on: .right, over: Self.a)
        store.open(Self.e, on: .bottom, over: Self.b)
        store.toggleFloating(Self.b)
        store.toggleFloating(Self.e)
        #expect(store.focusOrder == [Self.a, Self.b, Self.e])
        store.selectMember(Self.b)
        #expect(store.floating.map(\.ref) == [Self.e, Self.b])
        #expect(store.focusOrder == [Self.a, Self.b, Self.e])
        store.selectMember(Self.e)
        #expect(store.focusOrder == [Self.a, Self.b, Self.e])
    }

    @Test("A resized pair keeps its share after one card moves within that pair")
    func resizedPairKeepsItsShare() {
        var store = WorkspaceStore(selection: Self.a)
        store.open(Self.b, on: .bottom, over: Self.a)
        store.resize(to: 0.65)
        store.open(Self.b, on: .right, over: Self.a)
        #expect(store.layout?.share(at: []) == 0.65)
        #expect(!store.stacked)
    }

    @Test("A legacy saved pair migrates with its exact members, focus, orientation and size")
    func legacyPairMigrates() {
        var shares = CardShares()
        shares.set(0.375, for: [Self.a, Self.b])
        let store = WorkspaceStore(selection: Self.b, panes: [Self.a, Self.b], stacked: true, shares: shares)
        #expect(store.panes == [Self.a, Self.b])
        #expect(store.selection == Self.b)
        #expect(store.stacked)
        #expect(store.tabRoot(for: Self.b) == Self.a)
        #expect(store.shares.share(of: store.panes) == 0.375)
    }

    @Test("A legacy selection outside the saved pair does not discard either of the old pair's terminals")
    func inconsistentLegacySelectionDoesNotLoseThePair() {
        var store = WorkspaceStore(selection: Self.c, panes: [Self.a, Self.b], stacked: true)
        #expect(store.panes == [Self.c])
        store.selectTab(Self.a)
        #expect(store.panes == [Self.a, Self.b])
        #expect(store.stacked)
    }

    @Test("An asynchronous split joins its original tab rather than replacing work in the newly selected tab")
    func splitKeepsItsOriginalTarget() {
        var store = Self.twoTabs()
        store.open(Self.e, on: .right, over: Self.b, beside: Self.a)
        #expect(store.panes == [Self.a, Self.e, Self.b])
        #expect(store.tabMembers(Self.c) == [Self.c, Self.d])
        #expect(store.tabMembers(Self.b) == [Self.a, Self.e, Self.b])
    }

    @Test("Returning from Akyl restores the saved layout while preserving terminals regrouped during the visit")
    func akylReturnRestoresTheSnapshot() throws {
        var store = WorkspaceStore(selection: Self.a)
        store.open(Self.b, on: .left, over: Self.a)
        store.resize(to: 0.375)
        store.toggleZoom(Self.b)
        let bookmark = store.bookmark(host: "mac")
        let savedID = try #require(store.activeID)
        store.open(Self.e, on: .right, over: Self.b)
        store.selectMember(Self.c)
        store.open(Self.b, on: .bottom, over: Self.c)
        store.restore(bookmark)
        #expect(store.activeID == savedID)
        #expect(store.panes == [Self.b, Self.a])
        #expect(store.tabRoot(for: Self.b) == Self.a)
        #expect(store.selection == Self.b)
        #expect(store.zoomed == Self.b)
        #expect(store.shares.share(of: store.panes) == 0.375)
        #expect(store.tabMembers(Self.c) == [Self.c])
        #expect(store.tabMembers(Self.e) == [Self.e])
        #expect(Set(store.groups.flatMap(\.members)) == [Self.a, Self.b, Self.c, Self.e])
        #expect(store.groups.flatMap(\.members).count == 4)
    }

    @Test("Renaming a bookmarked member survives relaunch and returns to the renamed terminal")
    func akylBookmarkRenameSurvivesPersistence() throws {
        var store = WorkspaceStore(selection: Self.a)
        store.open(Self.b, on: .left, over: Self.a)
        store.toggleZoom(Self.b)
        var bookmark = store.bookmark(host: "mac")
        store.rename(Self.b, to: Self.e)
        bookmark.rename(Self.b, to: Self.e)
        let data = try AkylDocument.encoder().encode(bookmark)
        let saved = try AkylDocument.decoder().decode(AkylVisit.Navigation.self, from: data)
        store.selectMember(Self.c)
        store.restore(saved)
        #expect(store.panes == [Self.e, Self.a])
        #expect(store.selection == Self.e)
        #expect(store.zoomed == Self.e)
        #expect(store.tabRoot(for: Self.e) == Self.a)
        #expect(!store.groups.flatMap(\.members).contains(Self.b))
    }

    @Test("A floated card renamed during an Akyl visit tiles back into its saved split")
    func renamedAkylFloatingCardReturnsToItsSplit() throws {
        var store = WorkspaceStore(selection: Self.a)
        store.open(Self.b, on: .bottom, over: Self.a)
        store.resize(to: 0.375)
        let original = try #require(store.layout)
        store.toggleFloating(Self.b)
        var bookmark = store.bookmark(host: "mac")
        store.rename(Self.b, to: Self.e)
        bookmark.rename(Self.b, to: Self.e)
        store.selectMember(Self.c)
        store.restore(bookmark)
        store.toggleFloating(Self.e)
        #expect(store.layout == original.renaming(Self.b, to: Self.e))
    }

    @Test("A bookmarked terminal removed during the visit is not resurrected on return", arguments: [a, b])
    func akylReturnDoesNotResurrectRemovedMembers(_ removed: SessionRef) {
        var store = WorkspaceStore(selection: Self.a)
        store.open(Self.b, on: .right, over: Self.a)
        store.toggleZoom(Self.b)
        var bookmark = store.bookmark(host: "mac")
        store.remove([removed])
        bookmark.remove([removed])
        store.selectMember(Self.c)
        store.restore(bookmark)
        let survivor = removed == Self.a ? Self.b : Self.a
        #expect(store.panes == [survivor])
        #expect(store.selection == survivor)
        #expect(store.zoomed == nil)
        #expect(!store.groups.flatMap(\.members).contains(removed))
        #expect(store.tabMembers(Self.c) == [Self.c])
    }

    @Test("Returning to a floating-only bookmark keeps one copy of its card")
    func floatingOnlyAkylBookmarkDoesNotDuplicateItsCard() {
        var store = WorkspaceStore(selection: Self.a)
        store.toggleFloating(Self.a)
        let bookmark = store.bookmark(host: "mac")
        store.selectMember(Self.c)
        store.restore(bookmark)
        #expect(store.layout == nil)
        #expect(store.floating.map(\.ref) == [Self.a])
        #expect(store.panes == [Self.a])
        #expect(store.tabMembers(Self.c) == [Self.c])
        #expect(store.groups.flatMap(\.members).filter { $0 == Self.a }.count == 1)
    }

    @Test("Returning to an emptied bookmark shows no closed terminal and preserves the task tab")
    func emptyAkylBookmarkDoesNotCloseTheTask() {
        var store = WorkspaceStore(selection: Self.a)
        var bookmark = store.bookmark(host: "mac")
        store.remove([Self.a])
        bookmark.remove([Self.a])
        store.selectMember(Self.c)
        store.restore(bookmark)
        #expect(store.panes.isEmpty)
        #expect(store.selection == nil)
        #expect(store.tabMembers(Self.c) == [Self.c])
        #expect(store.groups.flatMap(\.members) == [Self.c])
    }

    @Test("A refreshed host list promotes an inactive tab's live partner after its root ended before relaunch")
    func unlistedInactiveRootDoesNotHideItsPartner() {
        var store = Self.twoTabs()
        let missing = store.unlisted(on: "mac", sessions: ["b"], attached: [Self.c, Self.d])
        #expect(missing == [Self.a])
        store.remove(missing)
        #expect(store.tabRoot(for: Self.b) == Self.b)
        #expect(store.tabMembers(Self.b) == [Self.b])
        #expect(store.panes == [Self.c, Self.d])
    }

    @Test("A host list taken before a new split does not remove either attached terminal")
    func staleListDoesNotCloseANewSplit() {
        let store = Self.twoTabs()
        let missing = store.unlisted(on: "mac", sessions: [], attached: [Self.a, Self.b])
        #expect(missing.isEmpty)
        #expect(store.tabMembers(Self.a) == [Self.a, Self.b])
    }

    @Test("A cross-host pair keeps its root host when selecting its other member after relaunch")
    func crossHostFocusKeepsTheTabRepresentative() throws {
        var store = WorkspaceStore(selection: Self.a)
        store.open(Self.c, on: .right, over: Self.a)
        let data = try PropertyListEncoder().encode(store)
        var restored = try PropertyListDecoder().decode(WorkspaceStore.self, from: data)
        restored.selectMember(Self.b)
        restored.selectTab(Self.c)
        #expect(restored.panes == [Self.a, Self.c])
        #expect(restored.selection == Self.c)
        #expect(restored.tabRoot(for: Self.c) == Self.a)
        restored.remove([Self.a])
        #expect(restored.tabRoot(for: Self.c) == Self.c)
        #expect(restored.selection == Self.c)
    }

    @Test("An old Akyl bookmark without group metadata restores its saved pair without replacing another tab")
    func legacyAkylBookmarkRestoresItsPair() throws {
        let data = Data(#"{"host":"mac","panes":["mac\ta","mac\tb"],"selection":"mac\tb","stacked":true,"shares":{}}"#.utf8)
        let bookmark = try AkylDocument.decoder().decode(AkylVisit.Navigation.self, from: data)
        var store = Self.twoTabs()
        store.restore(bookmark)
        #expect(store.panes == [Self.a, Self.b])
        #expect(store.selection == Self.b)
        #expect(store.stacked)
        #expect(store.tabMembers(Self.c) == [Self.c, Self.d])
    }
}
