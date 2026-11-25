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
    }
}
