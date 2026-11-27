import XCTest
import SwiftUI
@testable import BookTranslator

/// Renders the screens to PNG files for a visual check. Runs only with BT_SNAPSHOT_DIR set.
@MainActor
final class SnapshotTests: XCTestCase {
    /// The screens are rendered in the app's own defaults: put back every setting they change.
    private static let touchedKeys = ["appLanguage", "appearanceMode", "libraryLayout", "queuePaused", "targetLanguage"]
    private var savedSettings: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        savedSettings = Self.touchedKeys.reduce(into: [:]) { $0[$1] = UserDefaults.standard.object(forKey: $1) }
    }

    override func tearDown() {
        for key in Self.touchedKeys { UserDefaults.standard.set(savedSettings[key], forKey: key) }
        super.tearDown()
    }

    private func render<V: View>(_ view: V, name: String, size: CGSize, dark: Bool = false) throws {
        guard let dir = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] else { throw XCTSkip("no BT_SNAPSHOT_DIR") }
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func book4() -> QueueBook {
        var x = QueueBook(fileName: "c.epub", title: "The Hollow Crown")
        x.author = "Mara Ellison"; x.kind = .fiction; x.volumes = 1
        return x
    }

    private func mockPlan() -> DeletionPlan {
        var plan = DeletionPlan(folder: FileManager.default.temporaryDirectory.appendingPathComponent("bt-none"))
        plan.translations = ["A Study in Scarlet (Indonesian).epub"]
        plan.hasSource = true; plan.terms = 44; plan.hasStyle = true; plan.hasProgress = true
        plan.series = "Sherlock Holmes"; plan.bytes = 2_400_000
        return plan
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
        run.volume = 3; run.pct = 62; run.step = "translate"; run.polishPlanned = true
        run.times = ["prepare": 194, "translate": 1530]
        m.books = [run, b("The Silver Heron", "Mara Ellison", .fiction, 4, 180, .ready),
                   b("The Moonlit Archive", "Kenji Aoki", .fiction, 5, 360, .needsReview),
                   b("The Ledger of Small Things", "Tom Hale", .nonfiction, 1, 35, .uploaded),
                   b("A Short Guide to Soil Science", "Elena Ruiz", .nonfiction, 1, 40, .uploaded)]
        m.runningID = run.id
        m.engines = [EngineInfo(name: "claude", label: "Claude", active: true, reason: "ok", role: "main"),
                     EngineInfo(name: "codex", label: "Codex", active: true, reason: "ok", role: "backup"),
                     EngineInfo(name: "agy", label: "Antigravity", active: false, reason: "Quota exhausted, resets Monday 14:30", role: ""),
                     EngineInfo(name: "opencode", label: "OpenCode", active: false, reason: "no recommended model yet", role: "")]
        m.status = EngineStatus(state: "running", book: "x", title: "x", volume: 3, volumes: 10, pct: 62, engine: "Claude")
        return m
    }

    private func env<V: View>(_ v: V, _ m: AppModel) -> some View {
        v.environment(m).environment(Loc.shared).environment(Updater()).environment(AppearanceStore.shared)
    }

    func testScreens() throws {
        let m = model()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))   // let the initial library scan finish first
        m.library.books = m.mockLibrary
        m.library.frozen = true
        let size = CGSize(width: 1180, height: 696)
        try render(env(InputView(onStart: {}), m), name: "1-input", size: size)
        try render(env(RootView(), m), name: "0-root-light", size: size)
        try render(env(RootView(), m), name: "0-root-dark", size: size, dark: true)
        try render(env(InputView(onStart: {}), m), name: "1-input-dark", size: size, dark: true)
        try render(env(ProcessView {}, m), name: "2-process-dark", size: size, dark: true)
        try render(env(LibraryScreen(openFolder: .constant(nil)), m), name: "3-library-dark", size: size, dark: true)
        try render(env(SettingsView(), m), name: "4-settings-dark", size: CGSize(width: 700, height: 900), dark: true)
        Loc.shared.language = .id
        try render(env(ProcessView {}, m), name: "D-process-running-id", size: size)
        try render(env(ProcessView {}, m), name: "D-process-running-dark-id", size: size, dark: true)
        let stopped = model()
        stopped.runningID = nil; stopped.paused = true
        var half = stopped.books[0]
        half.stage = .approved; half.workdir = "hollow"; half.step = "refine"; half.polishing = true; half.pct = 41
        half.times = ["prepare": 194, "translate": 4210, "refine": 905]
        stopped.books[0] = half
        try render(env(ProcessView {}, stopped), name: "D-process-paused-id", size: size)
        try render(env(ProcessView {}, stopped), name: "D-process-narrow-id", size: CGSize(width: 940, height: 640))
        let ended = model()
        ended.books = Array(ended.books.dropFirst()); ended.runningID = nil
        var last = book4()
        last.step = "check"; last.pct = 100; last.times = ["prepare": 194, "translate": 4210, "refine": 2105, "check": 4]
        let verdict = CheckReport(overall: "warn", volumes: [.init(index: 1, overall: "warn", checks: [
            .init(id: "file", level: "ok", count: 0, items: []), .init(id: "pages", level: "ok", count: 0, items: []),
            .init(id: "quotes", level: "warn", count: 1, items: ["split_1.html: single"]),
            .init(id: "names", level: "info", count: 1, items: ["Monks (like Monks', 3x)"])])])
        ended.finished = FinishedBook(folder: "hollow", book: last, report: verdict)
        try render(env(ProcessView(goInput: {}), ended), name: "E-process-finished-id", size: size)
        var checked = ended.mockLibrary[0]; checked.check = verdict
        try render(env(CheckCard(book: checked).padding(16), ended), name: "E-check-card-id", size: CGSize(width: 330, height: 420))
        let target = mockPlan()
        try render(env(DeleteBookSheet(book: m.mockLibrary[0], plan: target, close: { _ in }), m), name: "D-delete-id", size: CGSize(width: 480, height: 600))
        try render(env(SettingsView(height: 1700), m), name: "4-settings-full-id", size: CGSize(width: 700, height: 1700))
        Loc.shared.language = .en
        try render(env(ProcessView {}, m), name: "2-process", size: size)
        try render(env(LibraryScreen(openFolder: .constant(nil)), m), name: "3-library-mock", size: size)
        for width in [1180, 980, 940, 760] {
            try render(env(LibraryScreen(openFolder: .constant(nil)), m), name: "9-library-w\(width)", size: CGSize(width: width, height: 330), dark: true)
        }
        try render(env(AboutView(), m), name: "C-about", size: CGSize(width: 540, height: 680))
        try render(env(AboutView(), m), name: "C-about-dark", size: CGSize(width: 540, height: 680), dark: true)
        m.env.isBuiltIn = true
        for (name, state) in [("needs", EngineSetup.State.needsSetup), ("working", .working), ("nopython", .noPython), ("failed", .failed("pip could not reach the internet"))] {
            m.engineSetup.state = state
            if state == .working { m.engineSetup.progress = "Collecting lxml"; m.engineSetup.stepsDone = 12 }
            try render(env(EngineSetupView(), m), name: "B-setup-\(name)", size: CGSize(width: 900, height: 420), dark: name == "failed")
        }
        m.env.isBuiltIn = false
        // Narrowest window, Indonesian (the longer labels), every main screen.
        Loc.shared.language = .id
        let narrow = CGSize(width: 940, height: 640)
        try render(env(InputView(onStart: {}), m), name: "A-input-narrow-id", size: narrow, dark: true)
        try render(env(ProcessView {}, m), name: "A-process-narrow-id", size: narrow, dark: true)
        try render(env(LibraryScreen(openFolder: .constant(nil)), m), name: "A-library-narrow-id", size: narrow, dark: true)
        try render(env(BookDetailView(book: m.library.books[2], onBack: {}), m), name: "A-detail-narrow-id", size: narrow, dark: true)
        Loc.shared.language = .en
        UserDefaults.standard.set("covers", forKey: "libraryLayout")
        try render(env(LibraryScreen(openFolder: .constant(nil)), m), name: "3-library-covers", size: size)
        try render(env(LibraryScreen(openFolder: .constant(nil)), m), name: "3-library-covers-dark", size: size, dark: true)
        UserDefaults.standard.removeObject(forKey: "libraryLayout")
        try render(env(BookDetailView(book: m.library.books[2], onBack: {}), m), name: "3-detail-mock", size: size)
        try render(env(BookDetailView(book: m.library.books[2], onBack: {}), m), name: "3-detail-mock-dark", size: size, dark: true)
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
        if let real = ProcessInfo.processInfo.environment["BT_REAL_EPUB"] {
            var book = m.library.books[0]
            book.title = "A Study in Scarlet"; book.authorName = "Sir Arthur Conan Doyle"; book.folder = "real"
            book.volumes = [VolumeInfo(index: 1, label: "x", output: real, status: "completed", title: nil, finishedAt: nil, metadataMissing: [], qaFlags: 0)]
            m.library.books.append(book)
            try render(env(BookDetailView(book: book, onBack: {}), m), name: "3-detail-real", size: size)
            try render(env(BookDetailView(book: book, onBack: {}), m), name: "3-detail-real-dark", size: size, dark: true)
        }
        var found = MetadataCandidate(source: .openLibrary, title: "A Study in Scarlet")
        found.matchedByISBN = true; found.sources = [.openLibrary]; found.authors = ["Arthur Conan Doyle"]; found.publisher = "Ward Lock"; found.date = "1887"
        found.subjects = ["Detective", "Mystery"]; found.isbn = "9782070631858"; found.coverURL = URL(string: "https://example.invalid/c.jpg")
        var other = found; other.id = UUID(); other.matchedByISBN = false; other.title = "A Study in Scarlet [adaptation]"; other.publisher = "Gilberton"; other.date = "1953"
        var cur = EpubMetadata(); cur.identifiers = ["9781599866741"]; cur.title = "A Study in Scarlet"; cur.creators = ["Sir Arthur Conan Doyle"]; cur.date = "2007-11-07T00:00:00+00:00"
        try render(env(MetadataLookupSheet(book: m.library.books[0], current: cur, onDone: { _ in }, preview: [found, other]), m), name: "7-lookup", size: CGSize(width: 900, height: 600))
        try render(env(MenuBarContent(), m), name: "6-menubar", size: CGSize(width: 320, height: 260))
        Loc.shared.language = .id
        try render(env(InputView(onStart: {}), m), name: "1-input-id", size: size)
        Loc.shared.language = .en
    }

    /// The pictures in the README: sample data only, in a whole window. Runs only with BT_README_DIR set.
    func testReadmeScreens() throws {
        guard let dir = ProcessInfo.processInfo.environment["BT_README_DIR"] else { throw XCTSkip("no BT_README_DIR") }
        Loc.shared.language = .en
        AppearanceStore.shared.mode = .light
        UserDefaults.standard.removeObject(forKey: "libraryLayout")      // the default, not this Mac's choice
        let m = model()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        m.library.books = m.mockLibrary
        m.library.frozen = true

        let work = m.env.booksDir.appendingPathComponent("moon")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let style = #"{"options":[{"id":"formal","name":"F","description":"d"},{"id":"santai","name":"S","description":"d"},{"id":"sastra","name":"L","description":"d"}],"recommended":"sastra","why":"The book is full of world building and epic names, so rich wording keeps its mood.","chosen":"sastra"}"#
        try style.write(to: work.appendingPathComponent("style.json"), atomically: true, encoding: .utf8)
        let terms = [("Aldric Vane", "Aldric Vane", "character"), ("Lyra Thorne", "Lyra Thorne", "character"),
                     ("Kaldmoor", "Kaldmoor", "place"), ("Ashen Sea", "Laut Abu", "place"), ("Silver Heron", "Silver Heron", "item"),
                     ("The Veil", "Tabir", "term"), ("Archivist", "Juru Arsip", "title")]
        let json = "{\"terms\":[" + terms.map {
            "{\"source\":\"\($0.0)\",\"target\":\"\($0.1)\",\"decision\":\"\($0.0 == $0.1 ? "keep" : "translate")\",\"category\":\"\($0.2)\"}"
        }.joined(separator: ",") + "]}"
        try json.write(to: work.appendingPathComponent("glossary.json"), atomically: true, encoding: .utf8)
        var moon = m.books[2]
        moon.workdir = "moon"

        let out = URL(fileURLWithPath: dir)
        // Windows near the app's smallest size, so the text stays readable when a README shrinks the picture;
        // the library is wider, to show every sample book.
        try capture(env(RootView(initialStage: .input), m), to: out, name: "add-books", size: CGSize(width: 960, height: 600))
        try capture(env(ReviewSheet(book: moon), m), to: out, name: "review", size: CGSize(width: 960, height: 620), titled: false)
        try capture(env(RootView(initialStage: .process), m), to: out, name: "progress", size: CGSize(width: 960, height: 600))
        try capture(env(RootView(initialStage: .library), m), to: out, name: "library", size: CGSize(width: 1180, height: 700))
    }

    /// A picture of the window as the window server draws it (corners, shadows and strokes as on screen).
    /// `CGWindowListCreateImage` is looked up by name because newer SDKs no longer declare it; a process may
    /// still picture its own windows without the screen-recording permission.
    private func capture<V: View>(_ view: V, to dir: URL, name: String, size: CGSize = CGSize(width: 1180, height: 700),
                                  titled: Bool = true) throws {
        let style: NSWindow.StyleMask = titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(size)
        window.orderBack(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        typealias Grab = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"))
        let onlyThisWindow: UInt32 = 1 << 3, withoutShadowAtFullSize: UInt32 = 1 << 0 | 1 << 3
        let image = try XCTUnwrap(unsafeBitCast(symbol, to: Grab.self)(.null, onlyThisWindow, UInt32(window.windowNumber),
                                                                       withoutShadowAtFullSize)?.takeRetainedValue())
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            .write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// The real window chrome: traffic lights and the header in one bar (a bare window with the same style).
    func testWindowChrome() throws {
        guard let dir = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] else { throw XCTSkip("no BT_SNAPSHOT_DIR") }
        let m = model()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: env(RootView(), m))
        window.orderBack(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("8-window.png"))
    }

    func testLibraryWithRealBook() throws {
        // <repository>/books, four levels above this file: no path of one Mac is written here.
        let root = (0..<4).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
            .appendingPathComponent("books")
        guard FileManager.default.fileExists(atPath: root.path) else { throw XCTSkip("no library") }
        let m = AppModel(env: BackendEnvironment(root: root.deletingLastPathComponent(), booksDir: root))
        m.library.books = LibraryStore.scan(root)
        XCTAssertFalse(m.library.books.isEmpty)
        let book = m.library.books[0]
        try render(env(BookDetailView(book: book, onBack: {}), m), name: "3-detail", size: CGSize(width: 1180, height: 696))
        try render(env(LibraryScreen(openFolder: .constant(nil)), m), name: "3-library", size: CGSize(width: 1180, height: 696))
    }
}
