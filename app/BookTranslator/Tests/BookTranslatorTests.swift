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

    func testAnOldAnswerIsAskedAgain() {
        let now = Date()
        func needs(_ state: Updater.State, ago: TimeInterval?) -> Bool {
            Updater.needsCheck(state, lastChecked: ago.map { now.addingTimeInterval(-$0) }, maxAge: 600, now: now)
        }
        XCTAssertTrue(needs(.idle, ago: 5))                 // nothing is shown yet
        XCTAssertFalse(needs(.upToDate, ago: 60))
        XCTAssertTrue(needs(.upToDate, ago: 3600))          // "latest" must not stay for days
        XCTAssertTrue(needs(.failed("x"), ago: 3600))
        XCTAssertTrue(needs(.upToDate, ago: nil))
        XCTAssertFalse(needs(.checking, ago: 3600))
        XCTAssertFalse(needs(.downloading, ago: 3600))
        let found = Updater.Release(version: "9", notes: "", url: URL(string: "https://x/a.zip")!)
        XCTAssertFalse(needs(.available(found), ago: 3600))
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

    func testEngineModelsOrderAndMissingModel() throws {
        let json = #"[{"name":"codex","label":"Codex","provider":"codex","path":"/x","active":true,"reason":"ok","role":"main","models":{"sonnet":"gpt-6-luna@high","haiku":"gpt-6-luna@high"}},{"name":"opencode","label":"OpenCode","provider":"opencode","path":"/y","active":false,"reason":"no recommended model yet: x","role":"","models":{}}]"#
        let found = try JSONDecoder().decode([EngineInfo].self, from: Data(json.utf8))
        XCTAssertEqual(found[0].modelName, "gpt-6-luna (high)")
        XCTAssertNil(found[1].modelName)
        XCTAssertTrue(found[1].lacksRecommendedModel)
        XCTAssertFalse(found[0].lacksRecommendedModel)
        XCTAssertEqual(EngineInfo.completeOrder(["agy", "claude", "codex"]), ["agy", "claude", "codex", "opencode"])
        XCTAssertEqual(EngineInfo.completeOrder([]), [])
    }
}

@MainActor
final class QueueTests: XCTestCase {
    /// These tests run in the app's own defaults: put back every setting they change.
    private static let touchedKeys = ["queuePaused", "targetLanguage", "polishNovels", "parallelRequests", "keepLog", "styleMode", "verifiedBooks",
                                      "keepModel"]
    private var savedSettings: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        savedSettings = Self.touchedKeys.reduce(into: [:]) { $0[$1] = UserDefaults.standard.object(forKey: $1) }
    }

    override func tearDown() {
        for key in Self.touchedKeys { UserDefaults.standard.set(savedSettings[key], forKey: key) }
        super.tearDown()
    }

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
    }

    func testPolishAndParallelBecomeEngineArguments() {
        let model = model()
        let book = QueueBook(fileName: "a.epub", title: "A", kind: .fiction)
        (model.polishNovels, model.parallelRequests) = (true, 1)
        XCTAssertFalse(model.baseArguments(book).contains("--no-refine"))
        XCTAssertFalse(model.baseArguments(book).contains("--parallel"))
        (model.polishNovels, model.parallelRequests) = (false, 3)
        XCTAssertTrue(model.baseArguments(book).contains("--no-refine"))
        XCTAssertEqual(Array(model.baseArguments(book).suffix(2)), ["--parallel", "3"])
        XCTAssertEqual(AppModel.clampParallel(0), 1)
        XCTAssertEqual(AppModel.clampParallel(9), 3)
    }

    /// A queue saved by 1.0.3 has no "polishing" field: 1.0.4 showed an empty queue after the update.
    func testQueueSavedByAnOlderVersionStillLoads() throws {
        let m = model()
        try FileManager.default.createDirectory(at: m.env.booksDir, withIntermediateDirectories: true)
        let old = #"""
        [{"id":"5F1AC97F-7385-4F75-86D0-238CD088A0E9","fileName":"a.epub","title":"A","author":"X","volumes":1,
          "kind":"fiksi","estimatedMinutes":9,"stage":"approved","reviewFirst":true,"style":"formal",
          "workdir":"A_X","volume":1,"pct":40,"error":""},
         {"fileName":"b.epub","title":"B","workdir":"B"}]
        """#
        try Data(old.utf8).write(to: m.env.queueFile)
        let books = AppModel.readQueue(file: m.env.queueFile, inbox: m.env.inbox)
        XCTAssertEqual(books.map(\.title), ["A", "B"])
        XCTAssertEqual(books.first?.pct, 40)
        XCTAssertEqual(books.first?.stage, .approved)
        XCTAssertEqual(books.first?.polishing, false)
        XCTAssertEqual(books.last?.stage, .uploaded)
    }

    func testAnUnreadableQueueIsKeptAside() throws {
        let m = model()
        try FileManager.default.createDirectory(at: m.env.booksDir, withIntermediateDirectories: true)
        try Data("not a queue".utf8).write(to: m.env.queueFile)
        XCTAssertTrue(AppModel.readQueue(file: m.env.queueFile, inbox: m.env.inbox).isEmpty)
        let copy = m.env.booksDir.appendingPathComponent(".app-queue.unreadable.json")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "not a queue")
    }

    func testTheLogIsOnUnlessSwitchedOff() {
        UserDefaults.standard.removeObject(forKey: "keepLog")
        let m = model()
        XCTAssertTrue(m.keepLog)
        XCTAssertFalse(m.env.makeProcess(["--detect"]).arguments?.contains("--no-log") ?? true)
        m.keepLog = false
        XCTAssertTrue(m.env.makeProcess(["--detect"]).arguments?.contains("--no-log") ?? false)
        XCTAssertEqual(m.env.logFolder.lastPathComponent, "_activity-log")
    }

    func testStyleModeDecidesWhetherABookWaitsForConfirmation() {
        UserDefaults.standard.removeObject(forKey: "styleMode")
        let m = model()
        XCTAssertEqual(m.styleMode, .manual)            // nothing changes for who never opened Settings
        m.books = [book("A", stage: .needsReview), book("B", stage: .needsReview), book("C", stage: .queued)]
        XCTAssertTrue(m.books.allSatisfy { m.reviewsFirst($0) })
        m.setReviewFirst(m.books[1].id, true)           // B asks for itself
        m.paused = true                                 // nothing may start in a test
        m.styleMode = .auto
        XCTAssertEqual(m.books.map(\.stage), [.approved, .needsReview, .queued])
        XCTAssertEqual(m.books.map { m.reviewsFirst($0) }, [false, true, false])
        m.setReviewFirst(m.books[2].id, true)
        XCTAssertTrue(m.reviewsFirst(m.books[2]))
        XCTAssertTrue(m.paused)
        XCTAssertFalse(m.baseArguments(m.books[0]).contains("--style"))   // the engine takes the recommended one
    }

    func testAPolishOnlyBookIsNotTranslatedAndIgnoresTheTranslationSettings() {
        let m = model()
        (m.polishNovels, m.parallelRequests) = (false, 3)
        var b = book("A", stage: .uploaded)
        b.volumes = 3; b.estimatedMinutes = 100
        m.books = [b, QueueBook(fileName: "b.txt", title: "B", stage: .uploaded)]
        m.setPolishOnly(m.books[0].id, true)
        m.setPolishOnly(m.books[1].id, true)                 // only an EPUB can be polished
        XCTAssertEqual(m.books.map(\.polishOnly), [true, false])
        let args = m.baseArguments(m.books[0])
        XCTAssertTrue(args.contains("--polish-only"))
        XCTAssertFalse(args.contains("--no-refine") || args.contains("--parallel"))
        XCTAssertEqual(m.books[0].shownVolumes, 1)            // never split
        XCTAssertEqual(m.books[0].expectedMinutes, 50)
        m.setPolishOnly(m.books[0].id, false)
        XCTAssertEqual(m.books[0].shownVolumes, 3)
        XCTAssertFalse(m.baseArguments(m.books[0]).contains("--polish-only"))
        m.books[0].stage = .queued                            // started: the choice is fixed
        m.setPolishOnly(m.books[0].id, true)
        XCTAssertFalse(m.books[0].polishOnly)
    }

    func testWaitingForALimitKeepsTheBookFirstInLine() throws {
        let m = model()                      // no engine folder: nothing actually runs
        m.paused = true
        XCTAssertFalse(m.baseArguments(book("A", stage: .queued)).contains("--one-engine"))
        m.keepModel = true
        XCTAssertTrue(m.baseArguments(book("A", stage: .queued)).contains("--one-engine"))
        m.books = [book("A", stage: .translating), book("B", stage: .queued)]
        try FileManager.default.createDirectory(at: m.env.booksDir, withIntermediateDirectories: true)
        let status = #"{"state":"waiting","book":"a","title":"A","volume":0,"volumes":1,"pct":0,"engine":"Claude"}"#
        try Data(status.utf8).write(to: m.env.statusFile)
        m.waitForLimit(m.books[0].id, folder: "a", stage: .approved, started: Date())
        let waiting = m.books[0]
        XCTAssertEqual(waiting.stage, .approved)
        XCTAssertEqual(waiting.workdir, "a")
        XCTAssertEqual(waiting.waitingFor, "Claude")
        XCTAssertEqual(try XCTUnwrap(waiting.retryAt).timeIntervalSinceNow, AppModel.retryDelay, accuracy: 5)
        XCTAssertEqual(m.currentBook?.id, waiting.id)          // shown on Progress, with its reason
        let saved = try JSONDecoder().decode([QueueBook].self, from: JSONEncoder().encode(m.books))
        XCTAssertEqual(saved[0].waitingFor, "Claude")
        XCTAssertNotNil(saved[0].retryAt)
        m.keepModel = false                                    // switching allowed: no reason to wait
        XCTAssertLessThanOrEqual(try XCTUnwrap(m.books[0].retryAt), Date())
    }

    func testPoorSourcesAreToldAndLayoutFindingsCanBeMended() throws {
        let json = #"{"file":"a.epub","title":"A","author":"","volumes":1,"source_language":"English","kind":"fiksi","estimated_minutes":1,"words":9,"warnings":["scanned"]}"#
        XCTAssertEqual(try JSONDecoder.snake.decode(InspectResult.self, from: Data(json.utf8)).warnings, ["scanned"])
        let old = json.replacingOccurrences(of: #","warnings":["scanned"]"#, with: "")
        XCTAssertNil(try JSONDecoder.snake.decode(InspectResult.self, from: Data(old.utf8)).warnings)
        for key in ["garbled", "scanned", "broken_paragraphs"] { XCTAssertNotNil(Loc.table["input.warn.\(key)"]) }
        func report(_ id: String, _ level: String) -> CheckReport {
            CheckReport(overall: level, volumes: [.init(index: 1, overall: level, checks: [.init(id: id, level: level, count: 1, items: [])])])
        }
        XCTAssertTrue(report("splits", "warn").canRepair)
        XCTAssertTrue(report("toc", "warn").canRepair)
        XCTAssertFalse(report("toc", "ok").canRepair)
        XCTAssertFalse(report("links", "warn").canRepair)
    }

    func testTheReadyCardWordingFollowsItsBooks() {
        let translate = book("A", stage: .ready)
        var polish = book("B", stage: .ready)
        polish.polishOnly = true
        XCTAssertEqual(QueueBook.wordingSuffix([]), "")
        XCTAssertEqual(QueueBook.wordingSuffix([translate]), "")
        XCTAssertEqual(QueueBook.wordingSuffix([polish]), ".polish")
        XCTAssertEqual(QueueBook.wordingSuffix([polish, translate]), ".mixed")
        for suffix in ["", ".polish", ".mixed"] {
            for base in ["input.ready", "input.readyHint", "input.start", "input.readyTitle1", "input.readyTitle"] {
                XCTAssertNotNil(Loc.table[base + suffix], base + suffix)
            }
        }
    }

    func testABookAlreadyInTheTargetLanguageIsRecognised() {
        XCTAssertTrue(QueueBook.isWritten("Indonesian", in: "Indonesian"))
        XCTAssertTrue(QueueBook.isWritten("Bahasa Indonesia ", in: "Indonesian"))
        XCTAssertFalse(QueueBook.isWritten("English", in: "Indonesian"))
        XCTAssertFalse(QueueBook.isWritten("", in: "Indonesian"))
    }

    func testAPolishOnlyBookSkipsTheTranslationStage() {
        var b = book("A", stage: .translating)
        b.polishOnly = true; b.workdir = "a_polish"; b.step = "refine"; b.polishing = true; b.pct = 30
        var steps = BookStage.steps(for: b, polishByDefault: false)
        XCTAssertEqual(steps.map(\.state), [.done, .skipped, .active, .pending])
        XCTAssertEqual(steps[0].titleKey, "stage.prepare.polish")
        b.step = "check"
        XCTAssertEqual(BookStage.steps(for: b, polishByDefault: false).map(\.state), [.done, .skipped, .done, .active])
        b.stage = .needsReview; b.step = "prepare"; b.pct = 0; b.polishing = false
        steps = BookStage.steps(for: b, polishByDefault: false)
        XCTAssertEqual(steps.map(\.state), [.done, .skipped, .pending, .pending])
    }

    func testThePolishChoiceSurvivesTheQueueFileAndTheLibrary() throws {
        var b = book("A", stage: .queued)
        b.polishOnly = true
        let back = try JSONDecoder().decode([QueueBook].self, from: JSONEncoder().encode([b]))
        XCTAssertTrue(back[0].polishOnly)
        let json = #"{"title":"A","mode":"polish","volumes":[]}"#
        XCTAssertTrue(try JSONDecoder.snake.decode(LibraryBook.self, from: Data(json.utf8)).isPolishOnly)
        let old = #"{"title":"A","volumes":[]}"#
        XCTAssertFalse(try JSONDecoder.snake.decode(LibraryBook.self, from: Data(old.utf8)).isPolishOnly)
        let pages = CheckReport.Item(id: "pages", level: "ok", count: 0, items: [])
        XCTAssertEqual(CheckStyle.key(pages, polishOnly: true), "check.polished.pages.ok")
        XCTAssertEqual(CheckStyle.key(pages, polishOnly: false), "check.pages.ok")
        let links = CheckReport.Item(id: "links", level: "warn", count: 1, items: ["a"])
        XCTAssertEqual(CheckStyle.key(links, polishOnly: true), "check.links.found")
    }

    func testStagesShowWhereABookStandsWithTheTimeSpent() {
        var b = book("A", stage: .translating)
        b.workdir = "a"
        b.step = "translate"; b.pct = 40; b.times = ["prepare": 75, "translate": 300]
        var steps = BookStage.steps(for: b, polishByDefault: true)
        XCTAssertEqual(steps.map(\.state), [.done, .active, .pending, .pending])
        XCTAssertEqual(steps.map(\.seconds), [75, 300, 0, 0])
        b.step = "refine"
        XCTAssertEqual(BookStage.steps(for: b, polishByDefault: false).map(\.state), [.done, .done, .active, .pending])
        b.step = "check"
        XCTAssertEqual(BookStage.steps(for: b, polishByDefault: true).map(\.state), [.done, .done, .done, .active])
        b.step = "translate"; b.polishPlanned = false          // the engine says this run does not polish
        XCTAssertEqual(BookStage.steps(for: b, polishByDefault: true).map(\.state), [.done, .active, .skipped, .pending])
        b = book("B", stage: .preparing)
        steps = BookStage.steps(for: b, polishByDefault: true)
        XCTAssertEqual(steps.map(\.state), [.active, .pending, .pending, .pending])
        b.stage = .approved; b.step = "prepare"; b.workdir = "b"      // prepared, not translating yet
        XCTAssertEqual(BookStage.steps(for: b, polishByDefault: true).map(\.state), [.done, .pending, .pending, .pending])
    }

    func testAStoppedBookKeepsItsProgressAcrossARestart() throws {
        let m = model()
        var b = book("A", stage: .translating)
        b.workdir = "A"; b.step = "refine"; b.pct = 35; b.polishing = true; b.times = ["prepare": 60, "translate": 900, "refine": 200]
        m.books = [book("Q", stage: .queued), b]
        AppModel.flushQueueWrites()
        let again = AppModel(env: m.env)
        XCTAssertEqual(again.currentBook?.title, "A")          // shown on Progress although nothing runs
        XCTAssertEqual(again.currentBook?.stage, .approved)
        XCTAssertEqual(again.currentBook?.pct, 35)
        XCTAssertEqual(again.currentBook?.times["translate"], 900)
        XCTAssertEqual(again.currentBook?.step, "refine")
    }

    func testDeletingABookListsWhatGoesAndMovesItToTheTrash() throws {
        let m = model()
        let fm = FileManager.default
        func make(_ name: String, series: String) throws -> URL {
            let folder = m.env.booksDir.appendingPathComponent(name)
            for sub in ["source", "translation", "previous"] {
                try fm.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
            }
            try Data("x".utf8).write(to: folder.appendingPathComponent("source/a.epub"))
            try Data("y".utf8).write(to: folder.appendingPathComponent("translation/a (Indonesian).epub"))
            try Data(#"{"title":"A","series":"\#(series)","volumes":[]}"#.utf8).write(to: folder.appendingPathComponent("book.json"))
            try Data(#"{"terms":[{"source":"a"},{"source":"b"}]}"#.utf8).write(to: folder.appendingPathComponent("glossary.json"))
            try Data("s".utf8).write(to: folder.appendingPathComponent("style.md"))
            return folder
        }
        let one = try make("bt-delete-\(UUID().uuidString)", series: "Saga")
        let two = try make("two", series: "saga")
        let plan = DeletionPlan(folder: one, others: [two])
        XCTAssertEqual(plan.translations, ["a (Indonesian).epub"])
        XCTAssertEqual(plan.terms, 2)
        XCTAssertTrue(plan.hasSource && plan.hasStyle)
        XCTAssertEqual(plan.series, "Saga")
        XCTAssertEqual(DeletionPlan(folder: one).series, "")

        var queued = book("Q", stage: .queued)
        queued.workdir = one.lastPathComponent
        m.books = [queued]
        XCTAssertNotNil(m.deleteBook(one.lastPathComponent))          // not while it is in the queue
        XCTAssertTrue(fm.fileExists(atPath: one.path))
        m.books = []
        XCTAssertNotNil(m.deleteBook("../outside"))
        XCTAssertNotNil(m.deleteBook("inbox"))
        XCTAssertNil(m.deleteBook(one.lastPathComponent))
        XCTAssertFalse(fm.fileExists(atPath: one.path))
        XCTAssertTrue(fm.fileExists(atPath: two.path))
        // the test's own folder must not be left in the user's Trash
        try? fm.removeItem(at: fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(one.lastPathComponent)"))
    }

    func testTheFinalCheckIsReadFromTheBookFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bt-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertNil(CheckReport.read(folder))
        let json = #"{"checked_at":"x","overall":"fail","volumes":[{"index":1,"overall":"fail","checks":[{"id":"file","level":"ok","count":0,"items":[]},{"id":"pages","level":"fail","count":2,"items":["a","b"]},{"id":"names","level":"info","count":1,"items":["c"]},{"id":"links","level":"warn","count":1,"items":["d"]}]}]}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("check.json"))
        try Data(#"{"title":"T","volumes":[]}"#.utf8).write(to: folder.appendingPathComponent("book.json"))
        let report = try XCTUnwrap(CheckReport.read(folder))
        XCTAssertTrue(report.needsLook)
        XCTAssertEqual(report.problems, 2)                       // information alone asks for nothing
        XCTAssertEqual(LibraryStore.read(folder: folder)?.check, report)
        for check in ["file", "pages", "paragraphs", "length", "untranslated", "quotes", "links", "names", "surplus", "metadata"] {
            XCTAssertNotNil(Loc.table["check.\(check).ok"], check)
            XCTAssertNotNil(Loc.table["check.\(check).found"], check)
        }
    }

    func testUnreadyAndKindToggle() {
        let m = model()
        m.books = [book("A", stage: .queued)]
        m.unready(m.books[0].id)
        XCTAssertEqual(m.books[0].stage, .uploaded)
        m.toggleKind(m.books[0].id)
        XCTAssertEqual(m.books[0].kind, .nonfiction)
    }

    func testQueueSurvivesRelaunchAndInterruptions() {
        let m = model()
        var b = book("A", stage: .translating)
        b.workdir = "A"
        m.books = [b, book("B", stage: .preparing)]
        AppModel.flushQueueWrites()
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

@MainActor
final class EngineSetupTests: XCTestCase {
    func testVersionRules() {
        XCTAssertEqual(EngineSetup.parseVersion("3.13\n")?.1, 13)
        XCTAssertNil(EngineSetup.parseVersion("nonsense"))
        XCTAssertTrue(EngineSetup.isSuitable((3, 10)))
        XCTAssertTrue(EngineSetup.isSuitable((3, 13)))
        XCTAssertFalse(EngineSetup.isSuitable((3, 9)))
        XCTAssertFalse(EngineSetup.isSuitable((2, 7)))
    }

    func testStateFollowsTheMarkerAndRequirements() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bt-setup-\(UUID().uuidString)")
        let engine = tmp.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        try "requests\n".write(to: engine.appendingPathComponent("requirements.txt"), atomically: true, encoding: .utf8)
        let setup = EngineSetup(supportDir: tmp.appendingPathComponent("support"))
        setup.check(engine: engine)
        XCTAssertEqual(setup.state, .needsSetup)

        // A finished environment: a python and a marker with this build's stamp.
        try FileManager.default.createDirectory(at: setup.python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: setup.python.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        try EngineSetup.stamp(engine: engine).write(to: setup.venv.appendingPathComponent(".bt-ready"), atomically: true, encoding: .utf8)
        setup.check(engine: engine)
        XCTAssertEqual(setup.state, .ready)

        // The engine's requirements changed in a new app version: the environment must be rebuilt.
        try "requests\nlxml\n".write(to: engine.appendingPathComponent("requirements.txt"), atomically: true, encoding: .utf8)
        setup.check(engine: engine)
        XCTAssertEqual(setup.state, .needsSetup)
    }

    func testBuiltInModeNeedsAPython() {
        var env = BackendEnvironment(root: URL(fileURLWithPath: "/tmp"), booksDir: URL(fileURLWithPath: "/tmp/b"))
        env.pythonOverride = URL(fileURLWithPath: "/nonexistent/python3")
        XCTAssertFalse(env.isReady)
    }
}


final class AboutTests: XCTestCase {
    func testAboutLinksAndEveryTextExists() {
        XCTAssertEqual(AboutPanel.repositoryURL.absoluteString, "https://github.com/aansun/NNAI-Translator")
        for key in AboutContent.hood + AboutContent.limits + ["about.buy.title", "about.buy.body", "about.license"] {
            XCTAssertNotNil(Loc.table[key], key)
        }
        XCTAssertEqual(AboutContent.hood.count, 5)
        XCTAssertEqual(AboutContent.limits.count, 7)
    }
}


final class OrphanEngineTests: XCTestCase {
    func testOnlyOrphanedEnginesOfThisAppAreFound() {
        let script = "/Applications/NNAI Translator.app/Contents/Resources/engine/translate_book.py"
        let ps = """
          100     1 /opt/homebrew/bin/Python \(script) --books-dir /Users/me/books -i x.epub
          101   100 /opt/homebrew/bin/Python \(script) --books-dir /Users/me/books -i child
          102     1 /opt/homebrew/bin/Python /Users/me/repo/translate_book.py --books-dir /Users/me/books
          103     1 /usr/bin/something else
          104     1 /opt/homebrew/bin/Python \(script) --detect
        """
        XCTAssertEqual(AppModel.orphanEngines(psOutput: ps, script: script), [100])
    }
}
