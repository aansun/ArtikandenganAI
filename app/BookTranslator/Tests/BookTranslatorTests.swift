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
        m.placeBefore(m.readyList[1].id, before: m.readyList[0].id)
        XCTAssertEqual(m.readyList.map(\.title), ["A", "C"])
        m.move(m.readyList[0].id, by: 1)
        XCTAssertEqual(m.readyList.map(\.title), ["C", "A"])
        XCTAssertFalse(m.canMove(m.readyList[0].id, by: -1))
        XCTAssertTrue(m.canMove(m.readyList[0].id, by: 1))
    }

    func testStartMovesReadyBooksIntoTheQueueInOrder() {
        let m = model()   // no engine folder, so nothing actually runs
        m.books = [book("Q", stage: .queued), book("A", stage: .ready), book("B", stage: .ready)]
        m.startReady()
        XCTAssertEqual(m.readyList.count, 0)
        XCTAssertEqual(m.queueList.map(\.title), ["Q", "A", "B"])
    }

    func testTargetLanguageIsFixedWhenABookJoinsTheQueue() {
        let m = model()
        m.targetLanguage = "Spanish"
        m.books = [book("A", stage: .ready)]
        m.startReady()
        XCTAssertEqual(m.books[0].targetLanguage, "Spanish")
        m.targetLanguage = "Japanese"                 // a later change does not touch queued books
        XCTAssertEqual(m.books[0].targetLanguage, "Spanish")
        m.targetLanguage = "Indonesian"
        UserDefaults.standard.removeObject(forKey: "targetLanguage")
    }

    func testUnreadyAndKindToggle() {
        let m = model()
        m.books = [book("A", stage: .queued)]
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
            b.authorName = a; b.series = a == "Ann" ? "Saga" : ""; b.isFiction = fiction; b.folder = t
            return b
        }
        let books = [lib("Zed", "Ann", fiction: true), lib("Alpha", "Bob", fiction: false), lib("Mid", "Ann", fiction: true)]
        let loc = Loc.shared
        let byKind = LibraryArranger.arrange(books, query: "", group: .kind, sort: .title, loc: loc)
        XCTAssertEqual(byKind.map { $0.books.count }, [2, 1])
        XCTAssertEqual(byKind[0].books.map(\.title), ["Mid", "Zed"])
        XCTAssertEqual(LibraryArranger.arrange(books, query: "alp", group: .none, sort: .title, loc: loc)[0].books.count, 1)
        XCTAssertEqual(LibraryArranger.arrange(books, query: "", group: .author, sort: .title, loc: loc).count, 2)
        let bySeries = LibraryArranger.arrange(books, query: "", group: .series, sort: .title, loc: loc)
        XCTAssertEqual(bySeries.map { $0.books.count }, [2, 1])
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


final class MetadataLookupTests: XCTestCase {
    func testOpenLibraryParsing() {
        let json = #"{"docs":[{"key":"/works/OL1W","title":"A Study in Scarlet","author_name":["Arthur Conan Doyle"],"first_publish_year":1887,"publisher":["Ward Lock"],"subject":["Detective","Mystery"],"isbn":["2070631850","9782070631858"],"cover_i":13405534},{"nokey":1}]}"#
        let found = MetadataLookup.parseOpenLibrary(Data(json.utf8))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].authors, ["Arthur Conan Doyle"])
        XCTAssertEqual(found[0].date, "1887")
        XCTAssertEqual(found[0].isbn, "9782070631858")
        XCTAssertEqual(found[0].coverURL?.absoluteString, "https://covers.openlibrary.org/b/id/13405534-L.jpg?default=false")
    }

    func testGoogleParsingAndError() {
        let json = #"{"items":[{"volumeInfo":{"title":"A Study in Scarlet","authors":["Arthur Conan Doyle"],"publisher":"Penguin","publishedDate":"2001-05-01","description":"Holmes.","categories":["Fiction"],"industryIdentifiers":[{"type":"ISBN_10","identifier":"0140437878"},{"type":"ISBN_13","identifier":"9780140437877"}],"imageLinks":{"thumbnail":"http://books.google.com/x.jpg"},"infoLink":"https://books.google.com/y"}}]}"#
        let found = MetadataLookup.parseGoogle(Data(json.utf8))
        XCTAssertEqual(found.first?.isbn, "9780140437877")
        XCTAssertEqual(found.first?.coverURL?.scheme, "https")
        XCTAssertEqual(found.first?.subjects, ["Fiction"])
        XCTAssertEqual(MetadataLookup.parseGoogleError(Data(#"{"error":{"code":429,"message":"Quota exceeded"}}"#.utf8)), "Quota exceeded")
        XCTAssertNil(MetadataLookup.parseGoogleError(Data(json.utf8)))
    }

    func testGoogleNeedsAKey() async {
        do { _ = try await MetadataLookup.googleBooks(title: "x", author: "", key: "") ; XCTFail("expected needsKey") }
        catch { XCTAssertEqual(error as? LookupError, .needsKey) }
    }

    func testAmazonLinkIsOnlyASearchPage() {
        let url = MetadataLookup.amazonSearchURL(title: "A Study in Scarlet", author: "Doyle")
        XCTAssertEqual(url.host, "www.amazon.com")
        XCTAssertTrue(url.absoluteString.contains("A%20Study%20in%20Scarlet"))
    }

    func testPlainDescriptionStripsHTML() {
        var m = EpubMetadata()
        m.description = #"<p class="description">RINGKASAN:<br>Satu &amp; dua</p>"#
        XCTAssertEqual(m.plainDescription, "RINGKASAN:\nSatu & dua")
        m.date = "2007-11-07T00:00:00+00:00"
        XCTAssertFalse(m.displayDate.contains("T00"))
        m.seriesIndex = "1.0"
        XCTAssertEqual(m.displaySeriesIndex, "1")
    }
}


final class IdentifyTests: XCTestCase {
    func testISBNChecksums() {
        XCTAssertEqual(ISBN.normalised("9781599866741"), "9781599866741")
        XCTAssertEqual(ISBN.normalised("urn:isbn:978-1-59986-674-1"), "9781599866741")
        XCTAssertEqual(ISBN.normalised("0-306-40615-2"), "0306406152")
        XCTAssertNil(ISBN.normalised("9781599866740"))        // wrong check digit
        XCTAssertNil(ISBN.normalised("urn:uuid:1234"))
        var m = EpubMetadata(); m.identifiers = ["urn:uuid:abc", "9781599866741"]
        XCTAssertEqual(m.isbn, "9781599866741")
    }

    func testDuplicateEditionsKeepTheISBNCopy() {
        var a = MetadataCandidate(source: .openLibrary, title: "A Study in Scarlet"); a.publisher = "Filiquarian"; a.date = "2007"
        var b = a; b.matchedByISBN = true; b.isbn = "9781599866741"
        let out = MetadataLookup.dedupe([a, b, MetadataCandidate(source: .openLibrary, title: "Other")])
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out[0].matchedByISBN)
    }

    func testDatesBecomeISO() {
        XCTAssertEqual(MetadataLookup.isoDate("November 7, 2007"), "2007-11-07")
        XCTAssertEqual(MetadataLookup.isoDate("2001-05"), "2001-05")
        XCTAssertEqual(MetadataLookup.isoDate("1887"), "1887")
        XCTAssertEqual(MetadataLookup.isoDate("sometime"), "sometime")
    }

    func testOpenLibraryISBNParsing() {
        let json = #"{"ISBN:9781599866741":{"title":"A Study in Scarlet","authors":[{"name":"Arthur Conan Doyle"}],"publishers":[{"name":"Filiquarian"}],"publish_date":"November 7, 2007","subjects":[{"name":"Detective"},{"name":"a very long subject name that is clearly not a genre at all"}],"cover":{"large":"https://covers.openlibrary.org/b/id/2974345-L.jpg"},"url":"http://openlibrary.org/books/OL1M"}}"#
        let found = MetadataLookup.parseOpenLibraryISBN(Data(json.utf8), isbn: "9781599866741")
        XCTAssertEqual(found.first?.publisher, "Filiquarian")
        XCTAssertEqual(found.first?.subjects, ["Detective"])
        XCTAssertEqual(found.first?.date, "November 7, 2007")
    }

    private func record(_ title: String, _ authors: [String], source: MetadataSource, isbn: Bool = false, publisher: String = "", description: String = "") -> MetadataCandidate {
        var c = MetadataCandidate(source: source, title: title)
        c.authors = authors; c.publisher = publisher; c.description = description; c.matchedByISBN = isbn
        return c
    }

    func testRankingPrefersTheExactEditionAndDropsAdaptations() {
        let exact = record("A Study in Scarlet", ["Arthur Conan Doyle"], source: .openLibrary, isbn: true, publisher: "Filiquarian")
        let adaptation = record("A Study in Scarlet [adaptation]", ["Arthur Conan Doyle"], source: .openLibrary, publisher: "Gilberton")
        let unrelated = record("Cooking for Two", ["Someone Else"], source: .openLibrary)
        let ranked = MetadataLookup.rank([adaptation, unrelated, exact], title: "A Study in Scarlet", author: "Arthur Conan Doyle")
        XCTAssertEqual(ranked.first?.publisher, "Filiquarian")
        XCTAssertFalse(ranked.contains { $0.title == "Cooking for Two" })
        XCTAssertLessThan(ranked.first(where: { $0.title.contains("adaptation") })?.score ?? 0, ranked.first?.score ?? 0)
    }

    func testMergeTakesDescriptionFromGoogleAndKeepsTheRest() {
        let ol = record("A Study in Scarlet", ["Arthur Conan Doyle"], source: .openLibrary, isbn: true, publisher: "Filiquarian")
        var g = record("A Study in Scarlet", ["Arthur Conan Doyle"], source: .googleBooks, isbn: true, description: "Holmes meets Watson.")
        g.coverURL = URL(string: "https://example.com/g.jpg")
        let ranked = MetadataLookup.rank([ol, g], title: "A Study in Scarlet", author: "Arthur Conan Doyle")
        let merged = try! XCTUnwrap(ranked.first)
        XCTAssertTrue(merged.combined)
        XCTAssertEqual(merged.publisher, "Filiquarian")
        XCTAssertEqual(merged.description, "Holmes meets Watson.")
        XCTAssertEqual(merged.coverURL?.absoluteString, "https://example.com/g.jpg")
        XCTAssertEqual(Set(merged.sources), [.openLibrary, .googleBooks])
        XCTAssertNil(MetadataLookup.merge([ol]))   // one source: nothing to combine
    }
}


final class CoverFetcherTests: XCTestCase {
    func testIsbnCoversComeBeforeTheSlowByIdLink() {
        var c = MetadataCandidate(source: .openLibrary, title: "x")
        c.isbn = "9781599866741"; c.altISBNs = ["9780140437877"]
        c.coverURL = URL(string: "https://covers.openlibrary.org/b/id/1-L.jpg?default=false")
        let urls = CoverFetcher.sources(for: c).map(\.absoluteString)
        XCTAssertTrue(urls[0].contains("/b/isbn/9781599866741"))
        XCTAssertTrue(urls[1].contains("books.google.com") && urls[1].contains("9781599866741"))
        XCTAssertTrue(urls.last!.contains("/b/id/1-L"))
        XCTAssertEqual(urls.count, 5)
        XCTAssertTrue(CoverFetcher.sources(for: MetadataCandidate(source: .googleBooks, title: "y")).isEmpty)
    }

    func testPlaceholdersAndNonImagesAreRejected() {
        XCTAssertFalse(CoverFetcher.isRealImage(Data(repeating: 0xFF, count: 500)))                       // too small
        XCTAssertFalse(CoverFetcher.isRealImage(Data("<html>".utf8) + Data(repeating: 0x20, count: 5_000))) // not an image
        XCTAssertTrue(CoverFetcher.isRealImage(Data([0xFF, 0xD8]) + Data(repeating: 0, count: 5_000)))
        XCTAssertTrue(CoverFetcher.isRealImage(Data([0x89, 0x50, 0x4E, 0x47]) + Data(repeating: 0, count: 5_000)))
    }
}
