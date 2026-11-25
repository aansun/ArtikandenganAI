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
        func lib(_ t: String, _ a: String, fiction: Bool, series: String = "", missing: Bool = false, vols: Int = 1) -> LibraryBook {
            let v = (1...vols).map { VolumeInfo(index: $0, label: t, output: "/x\($0).epub", status: "completed", title: t, finishedAt: nil, metadataMissing: missing ? ["series"] : [], qaFlags: 0) }
            var book = LibraryBook(title: t, titleTranslated: t, sourceLanguage: "English", targetLanguage: "Indonesian", genre: nil, isFiction: fiction,
                                   updatedAt: "2026-11-24T13:41:21Z", qaReport: nil, volumes: v)
            book.authorName = a; book.series = series; book.folder = t
            return book
        }
        let mockLibrary = [lib("A Study in Scarlet", "Arthur Conan Doyle", fiction: true, series: "Sherlock Holmes"),
                           lib("The Sign of the Four", "Arthur Conan Doyle", fiction: true, series: "Sherlock Holmes"),
                           lib("The Hound of the Baskervilles", "Arthur Conan Doyle", fiction: true, series: "Sherlock Holmes", missing: true),
                           lib("Pride and Prejudice", "Jane Austen", fiction: true), lib("Frankenstein", "Mary Shelley", fiction: true),
                           lib("Dracula", "Bram Stoker", fiction: true), lib("Meditations", "Marcus Aurelius", fiction: false),
                           lib("On the Origin of Species", "Charles Darwin", fiction: false), lib("Walden", "Henry David Thoreau", fiction: false, missing: true)]
        m.mockLibrary = mockLibrary
        run.volume = 3; run.pct = 62
        m.books = [run, b("The Silver Heron", "Mara Ellison", .fiction, 4, 180, .ready),
                   b("The Moonlit Archive", "Kenji Aoki", .fiction, 5, 360, .needsReview),
                   b("The Ledger of Small Things", "Tom Hale", .nonfiction, 1, 35, .uploaded),
                   b("A Short Guide to Soil Science", "Elena Ruiz", .nonfiction, 1, 40, .uploaded)]
        m.runningID = run.id
        m.engines = [EngineInfo(name: "claude", label: "Claude", active: true, reason: "ok", role: "main"),
                     EngineInfo(name: "codex", label: "Codex", active: true, reason: "ok", role: "backup"),
                     EngineInfo(name: "agy", label: "Antigravity", active: false, reason: "Quota exhausted, resets Monday 14:30", role: "")]
        m.status = EngineStatus(state: "running", book: "x", title: "x", volume: 3, volumes: 10, pct: 62, engine: "Claude")
        return m
    }

    private func env<V: View>(_ v: V, _ m: AppModel) -> some View {
        v.environment(m).environment(Loc.shared).environment(Updater())
    }

    func testScreens() throws {
        let m = model()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))   // let the initial library scan finish first
        m.library.books = m.mockLibrary
        m.library.frozen = true
        let size = CGSize(width: 1180, height: 696)
        try render(env(InputView(onStart: {}), m), name: "1-input", size: size)
        try render(env(ProcessView {}, m), name: "2-process", size: size)
        try render(env(LibraryScreen(openFolder: .constant(nil)), m), name: "3-library-mock", size: size)
        try render(env(BookDetailView(book: m.library.books[2], onBack: {}), m), name: "3-detail-mock", size: size)
        // Review sheet with files on disk
        let work = m.env.booksDir.appendingPathComponent("moon")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let style = #"{"options":[{"id":"formal","name":"F","description":"d"},{"id":"santai","name":"S","description":"d"},{"id":"sastra","name":"L","description":"d"}],"recommended":"sastra","why":"Disarankan: Sastra dan puitis. Buku ini penuh deskripsi dunia dan nama bergaya epik, jadi diksi yang kaya menjaga suasananya.","chosen":"sastra"}"#
        try style.write(to: work.appendingPathComponent("style.json"), atomically: true, encoding: .utf8)
        let terms = [("Aldric Vane","character","keep"),("Lyra Thorne","character","keep"),("Kaldmoor","place","keep"),("Ashen Sea","place","translate"),("Silver Heron","item","keep"),("The Veil","term","translate"),("Hollow Crown","term","keep"),("Archivist","title","translate")]
        let json = "{\"terms\":[" + terms.map { "{\"source\":\"\($0.0)\",\"target\":\"\($0.2 == "keep" ? $0.0 : "Terjemahan " + $0.0)\",\"decision\":\"\($0.2)\",\"category\":\"\($0.1)\"}" }.joined(separator: ",") + "]}"
        try json.write(to: work.appendingPathComponent("glossary.json"), atomically: true, encoding: .utf8)
        var moon = m.books[2]; moon.workdir = "moon"
        try render(env(ReviewSheet(book: moon), m), name: "5-review", size: CGSize(width: 1000, height: 680))
        try render(env(SettingsView(), m), name: "4-settings", size: CGSize(width: 700, height: 760))
        var found = MetadataCandidate(source: .openLibrary, title: "A Study in Scarlet")
        found.matchedByISBN = true; found.sources = [.openLibrary]; found.authors = ["Arthur Conan Doyle"]; found.publisher = "Ward Lock"; found.date = "1887"
        found.subjects = ["Detective", "Mystery"]; found.isbn = "9782070631858"; found.coverURL = URL(string: "https://example.invalid/c.jpg")
        var other = found; other.id = UUID(); other.matchedByISBN = false; other.title = "A Study in Scarlet [adaptation]"; other.publisher = "Gilberton"; other.date = "1953"
        var cur = EpubMetadata(); cur.identifiers = ["9781599866741"]; cur.title = "A Study in Scarlet"; cur.creators = ["Sir Arthur Conan Doyle"]; cur.date = "2007-11-07T00:00:00+00:00"
        try render(env(MetadataLookupSheet(book: m.library.books[0], current: cur, onDone: {}, preview: [found, other]), m), name: "7-lookup", size: CGSize(width: 900, height: 600))
        try render(env(MenuBarContent(), m), name: "6-menubar", size: CGSize(width: 320, height: 260))
        Loc.shared.language = .id
        try render(env(InputView(onStart: {}), m), name: "1-input-id", size: size)
        Loc.shared.language = .en
    }

    func testLibraryWithRealBook() throws {
        let root = URL(fileURLWithPath: "/Users/me/NNAI-Translator/books")
        guard FileManager.default.fileExists(atPath: root.path) else { throw XCTSkip("no library") }
        let m = AppModel(env: BackendEnvironment(root: root.deletingLastPathComponent(), booksDir: root))
        m.library.books = LibraryStore.scan(root)
        XCTAssertFalse(m.library.books.isEmpty)
        let book = m.library.books[0]
        try render(env(BookDetailView(book: book, onBack: {}), m), name: "3-detail", size: CGSize(width: 1180, height: 696))
        try render(env(LibraryScreen(openFolder: .constant(nil)), m), name: "3-library", size: CGSize(width: 1180, height: 696))
    }
}
