import XCTest
@testable import BookTranslator

final class UpdaterTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertTrue(Updater.isNewer("1.1.0", than: "1.0.0"))
        XCTAssertTrue(Updater.isNewer("v1.10", than: "1.9"))
        XCTAssertFalse(Updater.isNewer("1.0.0", than: "1.0"))
        XCTAssertFalse(Updater.isNewer("0.9.9", than: "1.0.0"))
    }

    func testReleaseParsing() {
        let json = """
        {"tag_name":"v1.2.0","body":"Notes","assets":[{"browser_download_url":"https://x/a.dmg"},{"browser_download_url":"https://x/app.zip"}]}
        """
        let release = Updater.parseRelease(Data(json.utf8))
        XCTAssertEqual(release?.version, "1.2.0")
        XCTAssertEqual(release?.url.absoluteString, "https://x/app.zip")
        XCTAssertNil(Updater.parseRelease(Data(#"{"tag_name":"v2","assets":[]}"#.utf8)))
    }

    func testShellQuoting() {
        XCTAssertEqual(Updater.shellQuote("/a b/it's"), "'/a b/it'\\''s'")
    }
}

final class EpubMetadataTests: XCTestCase {
    func testOPFParsing() {
        let opf = """
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>A Study in Scarlet</dc:title><dc:creator>Arthur Conan Doyle</dc:creator><dc:language>id</dc:language>
        <dc:subject>Mystery</dc:subject><dc:subject>Detective</dc:subject><dc:identifier>urn:uuid:1</dc:identifier>
        <meta name="cover" content="cov"/><meta name="calibre:series" content="Holmes"/>
        </metadata><manifest><item id="cov" href="images/cover.jpg" media-type="image/jpeg"/></manifest></package>
        """
        let meta = EpubReader.parse(opf: Data(opf.utf8))
        XCTAssertEqual(meta.title, "A Study in Scarlet")
        XCTAssertEqual(meta.creators, ["Arthur Conan Doyle"])
        XCTAssertEqual(meta.language, "id")
        XCTAssertEqual(meta.subjects.count, 2)
        XCTAssertEqual(meta.series, "Holmes")
        XCTAssertEqual(meta.coverHref, "images/cover.jpg")
    }
}

final class ModelDecodingTests: XCTestCase {
    func testBookJSON() throws {
        let json = """
        {"title":"T","title_translated":"T","source_language":"English","target_language":"Indonesian","is_fiction":true,
         "updated_at":"2026-11-24T13:41:21Z","volumes":[{"index":1,"label":"L","output":"/x.epub","status":"completed",
         "metadata_missing":["cover"],"qa_flags":2}]}
        """
        let book = try JSONDecoder.snake.decode(LibraryBook.self, from: Data(json.utf8))
        XCTAssertTrue(book.isComplete)
        XCTAssertEqual(book.kind, .fiction)
        XCTAssertEqual(book.missingCount, 1)
        XCTAssertEqual(book.qaFlagCount, 2)
        XCTAssertNotNil(book.updatedDate)
    }

    func testInspectAndStatus() throws {
        let inspect = #"{"file":"a.epub","title":"A","author":"B","volumes":3,"source_language":"English","kind":"fiksi","genre":"x","classified_by":"llm","words":100,"estimated_minutes":49}"#
        let info = try JSONDecoder.snake.decode(InspectResult.self, from: BackendClient.lastJSON(Data(("noise\n" + inspect + "\n").utf8)))
        XCTAssertEqual(info.volumes, 3)
        XCTAssertEqual(info.kind, .fiction)
        let status = #"{"state":"running","updated_at":"x","book":"b","title":"T","volume":2,"volumes":10,"pct":40,"engine":"Codex"}"#
        XCTAssertEqual(try JSONDecoder.snake.decode(EngineStatus.self, from: Data(status.utf8)).engine, "Codex")
    }

    func testEngineDecoding() throws {
        let json = #"[{"name":"claude","label":"Claude","provider":"claude-cli","path":"/x","active":true,"reason":"ok","role":"main"}]"#
        XCTAssertEqual(try JSONDecoder().decode([EngineInfo].self, from: Data(json.utf8)).first?.role, "main")
    }
}

@MainActor
final class QueueTests: XCTestCase {
    private func model() -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppModel(env: BackendEnvironment(root: dir, booksDir: dir.appendingPathComponent("books")))
    }

    private func book(_ title: String, stage: Stage) -> QueueBook {
        var b = QueueBook(fileName: "\(title).epub", title: title)
        b.stage = stage
        return b
    }

    func testReadyOrderAndReordering() {
        let m = model()
        m.books = [book("A", stage: .uploaded), book("B", stage: .uploaded), book("C", stage: .uploaded)]
        m.makeReady(m.books[2].id)   // C
        m.makeReady(m.books[0].id)   // A
        XCTAssertEqual(m.readyList.map(\.title), ["C", "A"])
        XCTAssertEqual(m.uploaded.map(\.title), ["B"])
        m.moveFirst(m.readyList[1].id)
        XCTAssertEqual(m.readyList.map(\.title), ["A", "C"])
        m.moveReady(from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(m.readyList.map(\.title), ["C", "A"])
    }

    func testUnreadyAndKindToggle() {
        let m = model()
        m.books = [book("A", stage: .ready)]
        m.unready(m.books[0].id)
        XCTAssertEqual(m.books[0].stage, .uploaded)
        m.toggleKind(m.books[0].id)
        XCTAssertEqual(m.books[0].kind, .nonfiction)
        XCTAssertFalse(m.books[0].reviewFirst)
    }

    func testQueueSurvivesRelaunchAndInterruptions() {
        let m = model()
        var b = book("A", stage: .translating)
        b.workdir = "A"
        m.books = [b, book("B", stage: .preparing)]
        let again = AppModel(env: m.env)
        XCTAssertEqual(again.books.first { $0.title == "A" }?.stage, .approved)
        XCTAssertEqual(again.books.first { $0.title == "B" }, nil) // its inbox file is gone
    }
}

final class ArrangeTests: XCTestCase {
    func testGroupingAndSearch() {
        func lib(_ t: String, _ a: String, fiction: Bool) -> LibraryBook {
            var b = LibraryBook(title: t, volumes: [])
            b.authorName = a; b.isFiction = fiction; b.folder = t
            return b
        }
        let books = [lib("Zed", "Ann", fiction: true), lib("Alpha", "Bob", fiction: false), lib("Mid", "Ann", fiction: true)]
        let loc = Loc.shared
        let byKind = LibraryArranger.arrange(books, query: "", group: .kind, sort: .title, loc: loc)
        XCTAssertEqual(byKind.map { $0.books.count }, [2, 1])
        XCTAssertEqual(byKind[0].books.map(\.title), ["Mid", "Zed"])
        XCTAssertEqual(LibraryArranger.arrange(books, query: "alp", group: .none, sort: .title, loc: loc)[0].books.count, 1)
        XCTAssertEqual(LibraryArranger.arrange(books, query: "", group: .author, sort: .title, loc: loc).count, 2)
    }
}

final class LocalizationTests: XCTestCase {
    func testEveryKeyHasBothLanguages() {
        for (key, pair) in Loc.table {
            XCTAssertFalse(pair.0.isEmpty, key)
            XCTAssertFalse(pair.1.isEmpty, key)
        }
    }

    func testFormatSpecifiersMatch() {
        for (key, pair) in Loc.table {
            let count = { (s: String) in s.components(separatedBy: "%").count - 1 }
            XCTAssertEqual(count(pair.0), count(pair.1), key)
        }
    }
}
