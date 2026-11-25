import XCTest
@testable import BookTranslator

/// Drives the real engine end to end. Runs only with BT_INTEGRATION=<epub path>; it calls the
/// signed-in CLIs, so it is not part of the normal test run.
@MainActor
final class IntegrationTests: XCTestCase {
    private func wait(_ what: String, timeout: TimeInterval, until condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { XCTFail("timeout waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    func testFullQueueRun() async throws {
        guard let epub = ProcessInfo.processInfo.environment["BT_INTEGRATION"] else { throw XCTSkip("BT_INTEGRATION not set") }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BT_ROOT"] ?? "")
        let books = FileManager.default.temporaryDirectory.appendingPathComponent("bt-int-\(UUID().uuidString)")
        let model = AppModel(env: BackendEnvironment(root: root, booksDir: books))
        XCTAssertTrue(model.env.isValid)
        model.notifyVolume = false; model.notifyAttention = false

        try await wait("engines", timeout: 120) { !model.enginesLoading && !model.engines.isEmpty }
        print("ENGINES", model.engines.map { "\($0.name):\($0.active):\($0.role)" })
        XCTAssertTrue(model.hasActiveEngine)

        model.addFiles([URL(fileURLWithPath: epub)])
        try await wait("inspect", timeout: 180) { model.books.first?.stage == .uploaded }
        let book = try XCTUnwrap(model.books.first)
        print("INSPECT", book.title, book.author, book.volumes, book.kind, book.estimatedMinutes)
        XCTAssertEqual(book.kind, .fiction)

        model.makeReady(book.id)
        model.startReady()
        try await wait("prepare/review", timeout: 900) { model.book(book.id)?.stage == .needsReview || model.book(book.id)?.stage == .failed }
        XCTAssertEqual(model.book(book.id)?.stage, .needsReview, model.book(book.id)?.error ?? "")
        let reviewed = try XCTUnwrap(model.book(book.id))
        let style = model.styleChoice(for: reviewed)
        print("REVIEW workdir=\(reviewed.workdir ?? "-") recommended=\(style?.recommended ?? "-") terms=\(model.glossaryTerms(for: reviewed).count)")
        XCTAssertNotNil(reviewed.workdir)
        XCTAssertNotNil(style)

        model.approve(book.id, style: style?.recommended ?? "auto")
        try await wait("translation", timeout: 1500) { (model.book(book.id) == nil || model.book(book.id)?.stage == .failed) && !model.isBusy }
        XCTAssertNil(model.book(book.id), model.book(book.id)?.error ?? "")
        XCTAssertTrue(model.queueIsClean)
        model.library.reload(env: model.env)
        try await wait("library", timeout: 60) { !model.library.books.isEmpty }
        let done = try XCTUnwrap(model.library.books.first)
        print("LIBRARY", done.title, done.isComplete, done.volumes.map(\.status), "author:", done.authorName)
        XCTAssertTrue(done.isComplete)
        let meta = EpubReader.read(URL(fileURLWithPath: try XCTUnwrap(done.volumes.first?.output)))
        print("META", meta?.language ?? "-", meta?.title ?? "-", meta?.creators ?? [], meta?.hasCover ?? false)
        XCTAssertEqual(meta?.language, "id")
    }
}

/// Live catalogue check; runs only with BT_LIVE=1 (it calls Open Library).
final class LiveLookupTests: XCTestCase {
    func testIdentifyByISBNAndByTitle() async throws {
        guard ProcessInfo.processInfo.environment["BT_LIVE"] == "1" else { throw XCTSkip("BT_LIVE not set") }
        let byISBN = await MetadataLookup.identify(isbn: "9781599866741", title: "A Study in Scarlet", author: "Arthur Conan Doyle", googleKey: nil)
        print("BYISBN", byISBN.records.prefix(3).map { "\($0.title)|\($0.publisher)|\($0.date)|isbn:\($0.matchedByISBN)|\(String(format: "%.2f", $0.score))" }, "notes:", byISBN.notes)
        XCTAssertEqual(byISBN.records.first?.publisher, "Filiquarian")
        XCTAssertTrue(byISBN.records.first?.matchedByISBN ?? false)
        let byTitle = await MetadataLookup.identify(isbn: nil, title: "A Study in Scarlet", author: "Arthur Conan Doyle", googleKey: nil)
        print("BYTITLE", byTitle.records.prefix(3).map { "\($0.title)|\($0.publisher)|\($0.date)|\(String(format: "%.2f", $0.score))" })
        XCTAssertFalse(byTitle.records.isEmpty)
        let top = try XCTUnwrap(byISBN.records.first)
        let started = Date()
        let data = await CoverFetcher.fetch(CoverFetcher.sources(for: top))
        print("COVER", data?.count ?? 0, "bytes in", String(format: "%.1f", Date().timeIntervalSince(started)), "s")
        XCTAssertNotNil(data.flatMap { NSImage(data: $0) })
    }
}

/// Applies metadata through the app's own edit path against the real engine. Runs only with
/// BT_EDIT_EPUB=<a translated epub> BT_ROOT=<engine folder> BT_COVER=<image>.
@MainActor
final class EditMetadataTests: XCTestCase {
    func testEditsReachTheEpub() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let epub = env["BT_EDIT_EPUB"], let root = env["BT_ROOT"], let cover = env["BT_COVER"] else { throw XCTSkip("not set") }
        let books = FileManager.default.temporaryDirectory.appendingPathComponent("bt-edit-\(UUID().uuidString)/books")
        let folder = books.appendingPathComponent("holmes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("b.epub")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: epub), to: copy)
        let book = #"{"title":"A Study in Scarlet","is_fiction":true,"volumes":[{"index":1,"label":"x","output":"\#(copy.path)","status":"completed","metadata_missing":[],"qa_flags":0}]}"#
        try book.write(to: folder.appendingPathComponent("book.json"), atomically: true, encoding: .utf8)

        let model = AppModel(env: BackendEnvironment(root: URL(fileURLWithPath: root), booksDir: books))
        let before = try XCTUnwrap(EpubReader.read(copy))
        XCTAssertNotEqual(before.publisher, "Test Publisher")

        for (field, value) in [("publisher", "Test Publisher"), ("isbn", "9780141439952"), ("subject", "Detective|Mystery"), ("cover", cover)] {
            let error = await model.editMetadata(folder: "holmes", field: field, value: value)
            XCTAssertNil(error, "\(field): \(error ?? "")")
        }
        let after = try XCTUnwrap(EpubReader.read(copy))
        XCTAssertEqual(after.publisher, "Test Publisher")
        XCTAssertTrue(after.identifiers.contains { ISBN.normalised($0) == "9780141439952" })
        XCTAssertEqual(after.subjects, ["Detective", "Mystery"])
        XCTAssertTrue(after.coverHref?.contains("cover-online") ?? false)
        print("EDITED", after.publisher, after.identifiers, after.subjects, after.coverHref ?? "-")
        let bad = await model.editMetadata(folder: "holmes", field: "nonsense", value: "x")
        XCTAssertNotNil(bad)          // a failure is reported, not swallowed
    }
}

/// Builds the built-in engine's Python environment for real (needs the internet and a Python 3.10+) and runs
/// the engine from it. Opt-in: BT_SETUP_TEST=1.
@MainActor
final class RealSetupTests: XCTestCase {
    func testInstallAndRunTheBundledEngine() async throws {
        guard ProcessInfo.processInfo.environment["BT_SETUP_TEST"] == "1" else { throw XCTSkip("BT_SETUP_TEST not set") }
        let engine = try XCTUnwrap(BackendEnvironment.bundledEngine, "this build has no engine inside it")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bt-real-setup-\(UUID().uuidString)")
        let setup = EngineSetup(supportDir: tmp.appendingPathComponent("support"))
        setup.check(engine: engine)
        XCTAssertEqual(setup.state, .needsSetup)

        let started = Date()
        await setup.install(engine: engine)
        print("SETUP state", setup.state, "in", Int(Date().timeIntervalSince(started)), "s, libraries seen:", setup.stepsDone)
        XCTAssertEqual(setup.state, .ready)
        setup.check(engine: engine)
        XCTAssertEqual(setup.state, .ready)

        var env = BackendEnvironment(root: engine, booksDir: tmp.appendingPathComponent("books"))
        env.pythonOverride = setup.python
        env.workDir = setup.supportDir
        env.isBuiltIn = true
        XCTAssertTrue(env.isReady)
        let engines = try await BackendClient.detect(env, refresh: true)
        print("ENGINES from the built-in engine:", engines.map { "\($0.name):\($0.active)" })
        XCTAssertEqual(engines.count, 3)

        // The engine runs read-only: nothing may be written into the app bundle.
        let leftovers = (FileManager.default.enumerator(at: engine, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "pyc" || $0.lastPathComponent == "__pycache__" }
        XCTAssertTrue(leftovers.isEmpty, "wrote into the bundle: \(leftovers.map(\.path))")
    }
}
