import XCTest
import SwiftUI
@testable import BookTranslator

/// Renders the screens to PNG files for a visual check. Runs only with BT_SNAPSHOT_DIR set.
@MainActor
final class SnapshotTests: XCTestCase {
    private func render<V: View>(_ view: V, name: String, size: CGSize) throws {
        guard let dir = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] else { throw XCTSkip("no BT_SNAPSHOT_DIR") }
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func model() -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bt-snap-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = AppModel(env: BackendEnvironment(root: dir, booksDir: dir.appendingPathComponent("books")))
        func b(_ t: String, _ a: String, _ k: BookKind, _ v: Int, _ mins: Int, _ s: Stage) -> QueueBook {
            var x = QueueBook(fileName: "\(t).epub", title: t)
            x.author = a; x.kind = k; x.volumes = v; x.estimatedMinutes = mins; x.stage = s
            return x
        }
        var run = b("The Hollow Crown", "Mara Ellison", .fiction, 10, 480, .translating)
        run.volume = 3; run.pct = 62
        m.books = [run, b("The Silver Heron", "Mara Ellison", .fiction, 4, 180, .ready),
                   b("The Moonlit Archive", "Kenji Aoki", .fiction, 5, 360, .needsReview),
                   b("The Ledger of Small Things", "Tom Hale", .nonfiction, 1, 35, .uploaded),
                   b("A Short Guide to Soil Science", "Elena Ruiz", .nonfiction, 1, 40, .uploaded)]
        m.runningID = run.id
        return m
    }

    private func env<V: View>(_ v: V, _ m: AppModel) -> some View {
        v.environment(m).environment(Loc.shared).environment(Updater())
    }

    func testScreens() throws {
        let m = model()
        let size = CGSize(width: 900, height: 620)
        try render(env(InputView(), m), name: "1-input", size: size)
        try render(env(ProcessView {}, m), name: "2-process", size: size)
        try render(env(SettingsView(), m), name: "4-settings", size: CGSize(width: 900, height: 1100))
        Loc.shared.language = .id
        try render(env(InputView(), m), name: "1-input-id", size: size)
        Loc.shared.language = .en
    }

    func testLibraryWithRealBook() throws {
        let root = URL(fileURLWithPath: "/Users/me/NNAI-Translator/books")
        guard FileManager.default.fileExists(atPath: root.path) else { throw XCTSkip("no library") }
        let m = AppModel(env: BackendEnvironment(root: root.deletingLastPathComponent(), booksDir: root))
        m.library.books = LibraryStore.scan(root)
        XCTAssertFalse(m.library.books.isEmpty)
        let book = m.library.books[0]
        try render(env(BookDetailView(book: book), m), name: "3-detail", size: CGSize(width: 520, height: 760))
        try render(env(LibraryScreen(), m), name: "3-library", size: CGSize(width: 900, height: 620))
    }
}
