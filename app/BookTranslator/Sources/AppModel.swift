import Foundation
import Observation
import UserNotifications
import AppKit

/// Collects the lines the engine prints, from the thread that reads its pipe.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private(set) var tail: [String] = []
    var onLine: (@Sendable (String) -> Void)?

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            lines.append(String(buffer[..<newline]))
            buffer.removeSubrange(...newline)
        }
        tail = Array((tail + lines).suffix(30))
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    var lastError: String {
        lock.lock(); defer { lock.unlock() }
        return tail.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }
}

@MainActor @Observable
final class AppModel {
    var env: BackendEnvironment
    var books: [QueueBook] = [] { didSet { saveQueue(); updateBadge() } }
    var engines: [EngineInfo] = []
    var enginesLoading = false
    var paused = false {
        didSet { UserDefaults.standard.set(paused, forKey: "queuePaused") }   // a pause the user chose survives a restart
    }
    var status: EngineStatus?
    var logLine = ""
    var reviewTarget: QueueBook.ID?
    var runningID: QueueBook.ID?
    var finished: FinishedBook?        // the last book that finished while the app ran
    var checking: String?              // the library folder being checked again
    var lastError = ""
    let library = LibraryStore()
    let engineSetup = EngineSetup()

    var quality: String = UserDefaults.standard.string(forKey: "quality") ?? "balanced" {
        didSet { UserDefaults.standard.set(quality, forKey: "quality") }
    }
    /// Manual is the default: a long run starts only after the user confirmed the style.
    var styleMode: StyleMode = StyleMode(rawValue: UserDefaults.standard.string(forKey: "styleMode") ?? "") ?? .manual {
        didSet {
            UserDefaults.standard.set(styleMode.rawValue, forKey: "styleMode")
            if styleMode == .auto && oldValue != .auto { releaseReviews() }
        }
    }
    /// The second pass that polishes a novel. Off: translated once.
    var polishNovels: Bool = UserDefaults.standard.object(forKey: "polishNovels") as? Bool ?? true {
        didSet { UserDefaults.standard.set(polishNovels, forKey: "polishNovels") }
    }
    /// Requests sent at once while translating (the polish pass always sends one at a time).
    var parallelRequests: Int = AppModel.clampParallel(UserDefaults.standard.integer(forKey: "parallelRequests")) {
        didSet { UserDefaults.standard.set(parallelRequests, forKey: "parallelRequests") }
    }
    /// On: a book is written by one engine only, and waits when its usage limit is reached.
    /// Off (the default): the next engine takes over, following the book's voice.
    var keepModel: Bool = UserDefaults.standard.bool(forKey: "keepModel") {
        didSet {
            UserDefaults.standard.set(keepModel, forKey: "keepModel")
            if !keepModel { books.filter { $0.retryAt != nil }.forEach { retryNow($0.id) } }
        }
    }
    /// The engine's exit code for "stopped by a usage limit", and how long until the next try.
    static let waitingExit: Int32 = 3
    static let retryDelay: TimeInterval = 20 * 60
    static let parallelChoices = 1...3
    static func clampParallel(_ value: Int) -> Int { min(max(value, parallelChoices.lowerBound), parallelChoices.upperBound) }
    var notifyVolume: Bool = UserDefaults.standard.object(forKey: "notifyVolume") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyVolume, forKey: "notifyVolume"); if notifyVolume { requestNotificationAccess() } }
    }
    var notifyAttention: Bool = UserDefaults.standard.object(forKey: "notifyAttention") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyAttention, forKey: "notifyAttention"); if notifyAttention { requestNotificationAccess() } }
    }
    var keepLog: Bool = BackendEnvironment.keepsLog {
        didSet { UserDefaults.standard.set(keepLog, forKey: "keepLog") }
    }
    var keepAwake: Bool = UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake") }
    }
    var addToBooks: Bool = UserDefaults.standard.object(forKey: "addToBooks") as? Bool ?? false {
        didSet { UserDefaults.standard.set(addToBooks, forKey: "addToBooks") }
    }
    /// Library folders whose metadata the user marked as checked.
    var verified: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "verifiedBooks") ?? []) {
        didSet { UserDefaults.standard.set(Array(verified), forKey: "verifiedBooks") }
    }
    var engineOrder: [String] = UserDefaults.standard.stringArray(forKey: "engineOrder") ?? [] {
        didSet {
            UserDefaults.standard.set(engineOrder, forKey: "engineOrder")
            env.engineOrder = engineOrder
        }
    }
    var targetLanguage: String = UserDefaults.standard.string(forKey: "targetLanguage") ?? "Indonesian" {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: "targetLanguage") }
    }
    var metadataBusy = false
    /// The books' own cover images (from their EPUB), shown wherever a queued book appears.
    var queueCovers: [QueueBook.ID: NSImage] = [:]
    /// Test hook: books to show before the first scan finishes.
    var mockLibrary: [LibraryBook] = []
    private var activity: NSObjectProtocol?
    private var lastVolumeSeen: [String: Int] = [:]
    private var addedToBooks: Set<String> = []

    private var runner: Task<Void, Never>?
    private var current: Process?
    private var killedForPause = false
    private var lastEngineLabel = ""

    /// ``deferStartup``: the app passes true so the window appears at once; reading the library folder can raise
    /// macOS's folder-access prompt, which blocks whatever thread asked, so it happens off the main thread.
    /// Tests keep the default and get a fully loaded model straight away.
    init(env: BackendEnvironment = .load(), deferStartup: Bool = false) {
        self.env = env
        self.env.engineOrder = UserDefaults.standard.stringArray(forKey: "engineOrder") ?? []
        if env.isBuiltIn, let engine = BackendEnvironment.bundledEngine {
            engineSetup.check(engine: engine)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            AppModel.flushQueueWrites()     // the last change to the queue must not be lost on quit
            MainActor.assumeIsolated { self?.current?.terminate() }   // do not leave the engine running without the app
        }
        if deferStartup {
            // The app that hosts the unit tests must not read, resume or rewrite the user's queue.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { Task { await startup() } }
        } else {
            applyQueue(Self.readQueue(file: env.queueFile, inbox: env.inbox))
            library.reload(env: env)
            refreshEngines()
        }
    }

    /// Engines left running by an app that was killed (not quit) keep working on the same book behind the app's
    /// back; they are stopped (the checkpoints keep the progress) before the queue takes over again.
    nonisolated static func orphanEngines(psOutput: String, script: String) -> [Int32] {
        psOutput.split(separator: "\n").compactMap { line -> Int32? in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let parent = Int32(parts[1]), parent == 1 else { return nil }
            let command = String(parts[2])
            return command.contains(script) && command.contains("--books-dir") ? pid : nil
        }
    }

    nonisolated static func reapOrphans(script: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let pids = orphanEngines(psOutput: String(decoding: data, as: UTF8.self), script: script)
        pids.forEach { kill($0, SIGTERM) }
        if !pids.isEmpty { try? await Task.sleep(nanoseconds: 2_500_000_000) }
    }

    /// After a restart the queue goes on by itself, unless the user had paused it.
    private func resumeAfterLaunch() async {
        await Self.reapOrphans(script: env.script.path)
        let runnable = books.contains { $0.stage == .queued || $0.stage == .approved }
        if runnable, !UserDefaults.standard.bool(forKey: "queuePaused"), env.isReady { start() }
    }

    private func startup() async {
        let current = env
        let outcome = await Task.detached(priority: .userInitiated) { () -> (URL?, [QueueBook]) in
            let legacy = BackendEnvironment.legacyLibrary()
            let target = legacy.map { BackendEnvironment(root: current.root, booksDir: $0) } ?? current
            return (legacy, AppModel.readQueue(file: target.queueFile, inbox: target.inbox))
        }.value
        if let legacy = outcome.0 {
            UserDefaults.standard.set(legacy.path, forKey: "booksDir")   // remembered: later launches skip the search
            env.booksDir = legacy
        }
        applyQueue(outcome.1)
        library.reload(env: env)
        refreshEngines()
        await resumeAfterLaunch()
    }

    // MARK: - Built-in engine

    /// The window shows the setup screen while the built-in engine has no Python environment yet.
    var needsEngineSetup: Bool { env.isBuiltIn && engineSetup.state != .ready && engineSetup.state != .unknown }

    /// Create (or repair) the built-in engine's Python environment, then use it.
    func runSetup() {
        guard let engine = BackendEnvironment.bundledEngine else { return }
        Task {
            await engineSetup.install(engine: engine)
            if engineSetup.state == .ready { refreshEngines(force: true) }
        }
    }

    /// Throw the environment away and build it again.
    func repairEngine() {
        guard let engine = BackendEnvironment.bundledEngine else { return }
        try? FileManager.default.removeItem(at: engineSetup.venv)
        engineSetup.check(engine: engine)
        runSetup()
    }

    /// Developer option: run a repository folder instead of the engine built into the app.
    func chooseDeveloperFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = Loc.shared.t("settings.engineFolderHint")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("translate_book.py").path) else {
            lastError = Loc.shared.t("settings.backendMissing")
            return
        }
        UserDefaults.standard.set(url.path, forKey: "backendRoot")
        env = BackendEnvironment.load()
        library.reload(env: env, force: true)
        refreshEngines(force: true)
    }

    func useBuiltInEngine() {
        UserDefaults.standard.removeObject(forKey: "backendRoot")
        env = BackendEnvironment.load()
        if let engine = BackendEnvironment.bundledEngine { engineSetup.check(engine: engine) }
        library.reload(env: env, force: true)
        refreshEngines(force: true)
    }

    // MARK: - Derived

    var uploaded: [QueueBook] { books.filter { $0.stage == .uploaded || $0.stage == .reading } }
    /// The right card of Add: chosen, not started.
    var readyList: [QueueBook] { books.filter { $0.stage == .ready } }
    /// The Progress queue: started books other than the one that runs now are waiting.
    var queueList: [QueueBook] { books.filter { $0.isQueued } }
    var running: QueueBook? { books.first { $0.id == runningID } }

    /// The book whose progress the Progress screen shows: the running one, else the one that
    /// was stopped part way (paused, or the app was closed) and goes on from there.
    var currentBook: QueueBook? {
        running ?? books.first {
            [.approved, .queued].contains($0.stage)
                && ($0.retryAt != nil || ($0.workdir != nil && ($0.pct > 0 || !$0.times.isEmpty)))
        }
    }
    var isBusy: Bool { runningID != nil }
    var hasActiveEngine: Bool { engines.contains { $0.active } }
    var waitingCount: Int { books.filter { [.queued, .approved].contains($0.stage) }.count }
    var queueIsClean: Bool { runner == nil && runningID == nil }
    var reviewBooks: [QueueBook] { books.filter { $0.stage == .needsReview } }

    func book(_ id: QueueBook.ID) -> QueueBook? { books.first { $0.id == id } }

    private func update(_ id: QueueBook.ID, _ change: (inout QueueBook) -> Void) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        change(&books[index])
    }

    /// Minutes left for the book that runs now.
    var remainingMinutes: Int? {
        guard let book = running, book.expectedMinutes > 0, book.shownVolumes > 0 else { return nil }
        let done = Double(max(book.volume - 1, 0) * 100 + book.pct) / Double(book.shownVolumes * 100)
        return max(1, Int(Double(book.expectedMinutes) * (1 - done)))
    }

    // MARK: - Engines

    func refreshEngines(force: Bool = false, reorder: Bool = false) {
        guard !enginesLoading, env.isReady else { return }
        enginesLoading = true
        let env = self.env
        Task {
            let found = try? await BackendClient.detect(env, refresh: force || reorder)
            self.engines = found ?? []
            self.enginesLoading = false
        }
    }

    // MARK: - Adding books

    func addFiles(_ urls: [URL]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: env.inbox, withIntermediateDirectories: true)
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let ext = url.pathExtension.lowercased()
            guard isDir.boolValue || ["epub", "txt"].contains(ext) else { continue }
            let target = uniqueDestination(for: url.lastPathComponent)
            do { try fm.copyItem(at: url, to: target) } catch { lastError = error.localizedDescription; continue }
            var book = QueueBook(fileName: target.lastPathComponent,
                                 title: target.deletingPathExtension().lastPathComponent
                                    .replacingOccurrences(of: "_", with: " "))
            book.stage = .reading
            books.append(book)
            inspect(book.id)
        }
    }

    private func uniqueDestination(for name: String) -> URL {
        let fm = FileManager.default
        var target = env.inbox.appendingPathComponent(name)
        var n = 2
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while fm.fileExists(atPath: target.path) {
            target = env.inbox.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return target
    }

    private func inspect(_ id: QueueBook.ID) {
        guard let book = book(id) else { return }
        let env = self.env
        let file = env.inbox.appendingPathComponent(book.fileName)
        Task {
            do {
                let info = try await BackendClient.inspect(env, file: file, target: targetLanguage)
                update(id) {
                    $0.title = info.title; $0.author = info.author; $0.volumes = max(info.volumes, 1)
                    $0.kind = info.kind; $0.estimatedMinutes = info.estimatedMinutes
                    $0.warnings = info.warnings ?? []
                    // translating a book into its own language makes no sense: offer the polish
                    $0.polishOnly = $0.canPolishOnly && QueueBook.isWritten(info.sourceLanguage, in: targetLanguage)
                    if $0.stage == .reading { $0.stage = .uploaded }
                }
                loadCover(for: id)
            } catch {
                update(id) { if $0.stage == .reading { $0.stage = .uploaded } }
                lastError = error.localizedDescription
            }
        }
    }

    func remove(_ id: QueueBook.ID) {
        guard let book = book(id), book.id != runningID else { return }
        if book.workdir == nil {
            try? FileManager.default.removeItem(at: env.inbox.appendingPathComponent(book.fileName))
        }
        books.removeAll { $0.id == id }
    }

    func toggleKind(_ id: QueueBook.ID) {
        update(id) { $0.kind = $0.kind.other }
    }

    /// Chosen before a book starts: translate it, or only polish a translation.
    func setPolishOnly(_ id: QueueBook.ID, _ value: Bool) {
        update(id) {
            guard [.uploaded, .ready].contains($0.stage), $0.workdir == nil else { return }
            $0.polishOnly = value && $0.canPolishOnly
        }
    }

    // MARK: - Queue order

    func makeReady(_ id: QueueBook.ID) {
        guard let index = books.firstIndex(where: { $0.id == id }), books[index].stage == .uploaded else { return }
        var item = books.remove(at: index)
        item.stage = .ready
        books.append(item)   // a book moved into the card goes to the end of it
    }

    func makeAllReady() { uploaded.filter { $0.stage == .uploaded }.forEach { makeReady($0.id) } }

    /// Back to the uploaded list (from the ready card or the queue), unless it runs now.
    func unready(_ id: QueueBook.ID) {
        guard let book = book(id), [.ready, .queued, .failed, .needsReview].contains(book.stage) else { return }
        update(id) { $0.stage = .uploaded; $0.error = "" }
    }

    /// Reorder inside one of the two ordered lists (ready card or queue), keeping everything else in place.
    private func reorder(_ subset: (QueueBook) -> Bool, _ change: (inout [QueueBook]) -> Void) {
        var picked = books.filter(subset)
        change(&picked)
        var iterator = picked.makeIterator()
        books = books.map { subset($0) ? (iterator.next() ?? $0) : $0 }
    }

    func placeBefore(_ id: QueueBook.ID, before target: QueueBook.ID) {
        guard id != target else { return }
        guard let moving = book(id), let dest = book(target), moving.stage == dest.stage else { return }
        let stage = moving.stage
        reorder({ $0.stage == stage }) { list in
            guard let from = list.firstIndex(where: { $0.id == id }) else { return }
            let item = list.remove(at: from)
            let at = list.firstIndex { $0.id == target } ?? list.count
            list.insert(item, at: at)
        }
    }

    func move(_ id: QueueBook.ID, by offset: Int) {
        guard let stage = book(id)?.stage else { return }
        let inQueue = stage != .ready
        let running = runningID
        reorder({ inQueue ? ($0.isQueued && $0.id != running) : $0.stage == .ready }) { list in
            guard let from = list.firstIndex(where: { $0.id == id }) else { return }
            let to = from + offset
            guard to >= 0, to < list.count else { return }
            list.swapAt(from, to)
        }
    }

    func canMove(_ id: QueueBook.ID, by offset: Int) -> Bool {
        guard let stage = book(id)?.stage else { return false }
        let list = stage == .ready ? readyList : queueList.filter { $0.id != runningID }
        guard let index = list.firstIndex(where: { $0.id == id }) else { return false }
        return list.indices.contains(index + offset)
    }

    /// Start button of Add: the ready books join the Progress queue, in order, and the queue runs.
    func startReady() {
        let ids = readyList.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let index = books.firstIndex(where: { $0.id == id }) else { continue }
            var item = books.remove(at: index)
            item.stage = .queued
            item.targetLanguage = item.targetLanguage ?? targetLanguage   // fixed from now on
            books.append(item)
        }
        start()
    }

    func reviewsFirst(_ book: QueueBook) -> Bool { book.reviewChoice ?? (styleMode == .manual) }

    func setReviewFirst(_ id: QueueBook.ID, _ value: Bool) { update(id) { $0.reviewChoice = value } }

    /// Switched to automatic: books waiting for a confirmation go on with the recommended style.
    private func releaseReviews() {
        let waiting = books.filter { $0.stage == .needsReview && !reviewsFirst($0) }.map(\.id)
        guard !waiting.isEmpty else { return }
        waiting.forEach { id in update(id) { $0.stage = .approved } }
        reviewTarget = nil
        if !paused { start() }
    }

    // MARK: - Running

    func start() {
        paused = false
        guard runner == nil else { return }
        guard env.isReady else { lastError = Loc.shared.t(env.isBuiltIn ? "setup.title" : "settings.backendMissing"); return }
        runner = Task { await runLoop(); runner = nil }
    }

    func pause() {
        paused = true
        killedForPause = true
        current?.terminate()
    }

    func resume() { start() }

    /// Try a waiting book at once instead of at its set time.
    func retryNow(_ id: QueueBook.ID) {
        update(id) { if $0.retryAt != nil { $0.retryAt = Date() } }
        start()
    }

    func retry(_ id: QueueBook.ID) {
        update(id) { $0.error = ""; $0.stage = $0.workdir == nil ? .queued : .approved }
        start()
    }

    func approve(_ id: QueueBook.ID, style: String) {
        update(id) { $0.style = style; $0.stage = .approved }
        reviewTarget = nil
        start()
    }

    private func nextBook() -> QueueBook? {
        books.first { $0.stage == .queued || $0.stage == .approved }
    }

    private func runLoop() async {
        if engines.isEmpty { engines = (try? await BackendClient.detect(env)) ?? [] }
        // a book that waits for a usage limit may find no engine active until then
        guard hasActiveEngine || books.contains(where: { $0.retryAt != nil }) else {
            lastError = Loc.shared.t("process.noEngine"); return
        }
        if keepAwake { activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Translating books") }
        defer {
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        }
        while !paused, let next = nextBook() {
            if let at = next.retryAt, at > Date() {              // the queue keeps its order: wait
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            runningID = next.id
            if next.stage == .queued && reviewsFirst(next) {      // not confirmed yet
                if next.workdir == nil || next.needsPrepare { await prepare(next) } else { askForReview(next) }
            } else {
                await translate(next)
            }
            runningID = nil
            status = nil
        }
        runningID = nil
    }

    /// The engine options of a run. Read when a book starts or resumes.
    func baseArguments(_ book: QueueBook) -> [String] {
        var args = ["--profile", quality, book.kind == .fiction ? "--fiction" : "--non-fiction",
                    "-tl", book.targetLanguage ?? "Indonesian"]
        if book.style != "auto" { args += ["--style", book.style] }
        if keepModel { args.append("--one-engine") }
        if book.polishOnly {                                   // one pass, one request at a time
            args.append("--polish-only")
        } else {
            if !polishNovels { args.append("--no-refine") }    // on: the engine polishes fiction only
            if parallelRequests > 1 { args += ["--parallel", "\(parallelRequests)"] }
        }
        return args
    }

    private func inputPath(_ book: QueueBook) -> String {
        guard let workdir = book.workdir else { return env.inbox.appendingPathComponent(book.fileName).path }
        let source = env.booksDir.appendingPathComponent(workdir).appendingPathComponent("source")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: source.path))?.sorted() ?? []
        return files.first.map { source.appendingPathComponent($0).path } ?? source.path
    }

    private func prepare(_ book: QueueBook) async {
        update(book.id) { $0.stage = .preparing; $0.error = ""; $0.retryAt = nil }
        let before = bookFolders()
        let started = Date()
        var args = ["-i", inputPath(book), "--prepare-only"] + baseArguments(book) + retryArguments(book)
        if let workdir = book.workdir { args += ["--workdir", env.booksDir.appendingPathComponent(workdir).path] }
        let (code, tail) = await runEngine(args, for: book.id)
        if paused && killedForPause {
            update(book.id) { $0.stage = .queued }
            return
        }
        if code == Self.waitingExit {
            update(book.id) { $0.needsPrepare = true }
            waitForLimit(book.id, folder: book.workdir ?? findWorkdir(for: book, before: before),
                         stage: .queued, started: started)
            return
        }
        guard code == 0, let workdir = book.workdir ?? findWorkdir(for: book, before: before) else {
            fail(book.id, tail)
            return
        }
        update(book.id) { $0.workdir = workdir; $0.needsPrepare = false; $0.waitingFor = "" }
        loadCover(for: book.id)
        if let prepared = self.book(book.id), reviewsFirst(prepared) {
            askForReview(prepared)
        } else {
            update(book.id) { $0.stage = .approved }       // switched to automatic while preparing
        }
    }

    private func askForReview(_ book: QueueBook) {
        update(book.id) { $0.stage = .needsReview }
        notify(Loc.shared.t("notify.review", book.title), Loc.shared.t("notify.reviewBody"))
    }

    private func translate(_ book: QueueBook) async {
        update(book.id) {
            if $0.waitingFor.isEmpty { $0.pct = 0 }     // a retry keeps showing how far the book is
            $0.stage = .translating; $0.error = ""; $0.retryAt = nil; $0.volume = max($0.volume, 0)
        }
        let started = Date()
        var args = ["-i", inputPath(book)] + baseArguments(book) + retryArguments(book)
            + (extraArguments[book.id] ?? [])
        if let workdir = book.workdir {
            args += ["--workdir", env.booksDir.appendingPathComponent(workdir).path]
        }
        let before = bookFolders()
        let (code, tail) = await runEngine(args, for: book.id)
        if killedForPause && paused {
            update(book.id) { $0.stage = $0.workdir == nil ? .queued : .approved }
            return
        }
        let folder = book.workdir ?? findWorkdir(for: book, before: before)
        if code == Self.waitingExit {
            extraArguments[book.id]?.removeAll { $0 == "--redo" }     // begun: the next try goes on
            waitForLimit(book.id, folder: folder, stage: .approved, started: started)
            return
        }
        if code == 0, let folder, let result = LibraryStore.read(folder: env.booksDir.appendingPathComponent(folder)),
           result.isComplete {
            var last = self.book(book.id) ?? book
            last.step = "check"; last.pct = 100
            finished = FinishedBook(folder: folder, book: last, report: result.check)
            books.removeAll { $0.id == book.id }
            library.reload(env: env)
            let needsLook = result.check?.needsLook ?? false
            let body = Loc.shared.t(last.polishOnly ? "notify.donePolishBody" : "notify.doneBody")
            notify(Loc.shared.t("notify.done", result.title),
                   needsLook ? CheckStyle.verdict(result.check, Loc.shared) : body, attention: needsLook)
            addCompletedVolumesToBooks(folder: folder)
        } else {
            update(book.id) { $0.workdir = $0.workdir ?? folder }
            fail(book.id, tail)
        }
    }

    /// A book that has waited asks the engines again: the answer kept a few minutes may be the old one.
    private func retryArguments(_ book: QueueBook) -> [String] {
        book.waitingFor.isEmpty ? [] : ["--refresh-engines"]
    }

    /// The engine stopped at a usage limit: the book stays first in line and is tried again later.
    func waitForLimit(_ id: QueueBook.ID, folder: String?, stage: Stage, started: Date) {
        let engine = (try? Data(contentsOf: env.statusFile))
            .flatMap { try? JSONDecoder.snake.decode(EngineStatus.self, from: $0) }?.engine.nonEmpty ?? "AI"
        // said once, and again only after a run that got somewhere
        let news = (book(id)?.waitingFor.isEmpty ?? true) || Date().timeIntervalSince(started) > 300
        update(id) {
            $0.stage = stage
            $0.workdir = $0.workdir ?? folder
            $0.waitingFor = engine
            $0.retryAt = Date().addingTimeInterval(Self.retryDelay)
        }
        if news, let waiting = book(id) {
            notify(Loc.shared.t("notify.waiting", engine), Loc.shared.t("notify.waitingBody", waiting.title))
        }
    }

    private func fail(_ id: QueueBook.ID, _ tail: String) {
        let title = book(id)?.title ?? ""
        update(id) { $0.stage = .failed; $0.error = tail }
        notify(Loc.shared.t("notify.failed", title), tail)
    }

    /// Runs the engine to the end and returns its exit code and the last line it said.
    private func runEngine(_ arguments: [String], for id: QueueBook.ID) async -> (Int32, String) {
        let process = env.makeProcess(arguments)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collector = LineCollector()
        collector.onLine = { [weak self] line in
            Task { @MainActor in self?.logLine = line.replacingOccurrences(of: "[agent] ", with: "") }
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in collector.feed(handle.availableData) }
        killedForPause = false
        current = process
        let poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollStatus(for: id)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        let code: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do { try process.run() } catch {
                collector.feed(Data("\(error.localizedDescription)\n".utf8))
                continuation.resume(returning: -1)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        poller.cancel()
        current = nil
        return (code, collector.lastError)
    }

    private func pollStatus(for id: QueueBook.ID) {
        guard let data = try? Data(contentsOf: env.statusFile),
              let status = try? JSONDecoder.snake.decode(EngineStatus.self, from: data) else { return }
        self.status = status
        update(id) {
            if $0.stage == .translating {
                // a run that is still preparing says volume 0: keep what a resumed book had
                if status.volume > 0 {
                    let polishing = status.phase == "refine"
                    // a resumed run says 0 before it has counted what is already done: keep the saved figure
                    if status.pct > 0 || status.volume != $0.volume || polishing != $0.polishing { $0.pct = status.pct }
                    $0.volume = status.volume
                    $0.polishing = polishing
                    $0.polishPlanned = status.polish
                }
                $0.volumes = max(status.volumes, $0.volumes)
            }
            if $0.stage == .translating || $0.stage == .preparing {
                if let step = status.stage, !step.isEmpty, status.volume > 0 || $0.pct == 0 { $0.step = step }
                for (stage, seconds) in status.times ?? [:] where status.volume > 0 || stage == "prepare" {
                    $0.times[stage] = seconds
                }
            }
        }
        if let running = book(id), let folder = running.workdir ?? Optional(status.book), status.volume > 0 {
            let seen = lastVolumeSeen[folder] ?? status.volume
            if status.volume > seen {
                notify(Loc.shared.t("notify.volume", seen, running.title), Loc.shared.t("notify.volumeBody"), attention: false)
                addCompletedVolumesToBooks(folder: folder)
            }
            lastVolumeSeen[folder] = max(seen, status.volume)
        }
        if !status.engine.isEmpty, status.engine != lastEngineLabel {
            if !lastEngineLabel.isEmpty {
                notify(Loc.shared.t("notify.engine", status.engine), Loc.shared.t("notify.engineBody"))
            }
            lastEngineLabel = status.engine
        }
    }

    private func bookFolders() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: env.booksDir.path)) ?? []
        return Set(names.filter { name in
            var isDir: ObjCBool = false
            return name != "inbox" && FileManager.default.fileExists(atPath: env.booksDir.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
        })
    }

    /// The folder the engine made for a book: the one that appeared during the run, else the
    /// one whose source is this book's file, else the one the status file names. (A preparation
    /// run writes no status file, so the status alone is not enough.)
    private func findWorkdir(for book: QueueBook, before: Set<String>) -> String? {
        let fresh = bookFolders().subtracting(before)
        if fresh.count == 1, let only = fresh.first { return only }
        // the same file may have a translation folder and a polish folder
        for name in bookFolders() where name.hasSuffix("_polish") == book.polishOnly {
            let state = env.booksDir.appendingPathComponent(name).appendingPathComponent("source")
            if (try? FileManager.default.contentsOfDirectory(atPath: state.path))?.contains(book.fileName) == true { return name }
        }
        return readStatusBook()
    }

    private func readStatusBook() -> String? {
        guard let data = try? Data(contentsOf: env.statusFile),
              let status = try? JSONDecoder.snake.decode(EngineStatus.self, from: data),
              FileManager.default.fileExists(atPath: env.booksDir.appendingPathComponent(status.book).path)
        else { return nil }
        return status.book
    }

    // MARK: - Review data

    func styleChoice(for book: QueueBook) -> StyleChoice? {
        guard let workdir = book.workdir else { return nil }
        let url = env.booksDir.appendingPathComponent(workdir).appendingPathComponent("style.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(StyleChoice.self, from: $0) }
    }

    func glossaryTerms(for book: QueueBook) -> [GlossaryTerm] {
        guard let workdir = book.workdir else { return [] }
        let url = env.booksDir.appendingPathComponent(workdir).appendingPathComponent("glossary.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Glossary.self, from: $0) }?.terms ?? []
    }

    func file(_ name: String, of book: QueueBook) -> URL? {
        book.workdir.map { env.booksDir.appendingPathComponent($0).appendingPathComponent(name) }
    }

    // MARK: - Library actions

    /// Translate a finished book again (`--redo`) or repair its metadata, as one more queue run.
    func runMaintenance(folder: String, arguments: [String]) {
        guard runner == nil, env.isReady else { return }
        let source = env.booksDir.appendingPathComponent(folder).appendingPathComponent("source")
        guard let first = (try? FileManager.default.contentsOfDirectory(atPath: source.path))?.sorted().first else { return }
        var book = QueueBook(fileName: first, title: library.book(folder: folder)?.title ?? folder)
        book.stage = .approved
        book.workdir = folder
        book.kind = library.book(folder: folder)?.kind ?? .fiction
        book.targetLanguage = library.book(folder: folder)?.targetLanguage ?? "Indonesian"
        book.volumes = library.book(folder: folder)?.volumes.count ?? 1
        book.polishOnly = library.book(folder: folder)?.isPolishOnly ?? false
        books.append(book)
        extraArguments[book.id] = arguments
        start()
    }

    var extraArguments: [QueueBook.ID: [String]] = [:]

    private func updateBadge() {
        let count = books.filter { $0.isQueued }.count
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: - Persistence

    private static let queueIO = DispatchQueue(label: "app.queue-io", qos: .utility)

    /// Waits until every queued write has reached the disk (on quit, and in tests).
    nonisolated static func flushQueueWrites() { queueIO.sync {} }

    private func saveQueue() {
        guard let data = try? JSONEncoder.pretty.encode(books) else { return }
        let dir = env.booksDir, file = env.queueFile
        Self.queueIO.async {          // off the main thread: the folder may need the user's permission
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// The saved queue, with books whose file is gone dropped and interrupted work put back in line. Reads the disk.
    nonisolated static func readQueue(file: URL, inbox: URL) -> [QueueBook] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let fm = FileManager.default
        guard var saved = try? JSONDecoder().decode([QueueBook].self, from: data) else {
            // The next change to the queue overwrites this file: keep what could not be read.
            let copy = file.deletingLastPathComponent().appendingPathComponent(".app-queue.unreadable.json")
            try? fm.removeItem(at: copy)
            try? fm.copyItem(at: file, to: copy)
            return []
        }
        saved = saved.filter { fm.fileExists(atPath: inbox.appendingPathComponent($0.fileName).path) || $0.workdir != nil }
        for index in saved.indices {
            switch saved[index].stage {
            case .reading: saved[index].stage = .uploaded
            case .preparing: saved[index].stage = .queued
            case .translating: saved[index].stage = saved[index].workdir == nil ? .queued : .approved
            default: break
            }
        }
        return saved
    }

    private func applyQueue(_ saved: [QueueBook]) {
        guard !saved.isEmpty else { return }
        books = saved
        saved.forEach { loadCover(for: $0.id) }
    }

    /// Reads the book's own cover from its EPUB, off the main thread: the file is in the inbox until the engine
    /// files it under books/<book>/source.
    func loadCover(for id: QueueBook.ID) {
        guard queueCovers[id] == nil, let book = book(id) else { return }
        let inbox = env.inbox.appendingPathComponent(book.fileName)
        let source = book.workdir.map { env.booksDir.appendingPathComponent($0).appendingPathComponent("source") }
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            var candidates: [URL] = []
            if let source, let names = try? fm.contentsOfDirectory(atPath: source.path) {
                candidates += names.sorted().map { source.appendingPathComponent($0) }
            }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: inbox.path, isDirectory: &isDir) {
                if isDir.boolValue, let names = try? fm.contentsOfDirectory(atPath: inbox.path) {
                    candidates += names.sorted().map { inbox.appendingPathComponent($0) }
                } else { candidates.append(inbox) }
            }
            guard let epub = candidates.first(where: { $0.pathExtension.lowercased() == "epub" }),
                  let image = EpubReader.cover(epub) else { return }
            await MainActor.run { self.queueCovers[id] = image }
        }
    }

    // MARK: - Estimates and engines

    /// When the running book should be done, from the engine's estimate and the progress so far.
    var estimatedFinish: Date? {
        remainingMinutes.map { Date().addingTimeInterval(Double($0) * 60) }
    }

    /// "Estimated to finish today around 12.51" for the running book ('' when unknown).
    func etaDescription(_ loc: Loc) -> String {
        guard let end = estimatedFinish else { return "" }
        let time = end.formatted(date: .omitted, time: .shortened)
        let cal = Calendar.current
        if cal.isDateInToday(end) { return loc.t("process.eta.today", time) }
        if cal.isDateInTomorrow(end) { return loc.t("process.eta.tomorrow", time) }
        return loc.t("process.eta.date", end.formatted(date: .abbreviated, time: .shortened))
    }

    var mainEngine: EngineInfo? { engines.first { $0.role == "main" } }
    var backupEngines: [EngineInfo] { engines.filter { $0.role == "backup" } }
    /// The engine that answered last, when it is not the main one (the main one is out).
    var switchedEngine: String? {
        guard let said = status?.engine.nonEmpty, let main = mainEngine, said != main.label else { return nil }
        return said
    }

    func moveEngine(_ name: String, before target: String) {
        var order = engines.map(\.name)
        guard name != target, let from = order.firstIndex(of: name) else { return }
        order.remove(at: from)
        order.insert(name, at: order.firstIndex(of: target) ?? order.count)
        engineOrder = order
        refreshEngines(force: false, reorder: true)
    }

    // MARK: - Checking a finished book again

    /// Runs the engine's last stage on a library book. Returns nil, else why it could not.
    func recheck(_ folder: String) async -> String? { await runCheck(folder, "--check") }

    /// Mends the layout of a finished book (no model is asked), then checks it again.
    func repair(_ folder: String) async -> String? { await runCheck(folder, "--repair") }

    private func runCheck(_ folder: String, _ command: String) async -> String? {
        guard checking == nil, env.isReady else { return nil }
        checking = folder
        defer { checking = nil }
        do {
            _ = try await BackendClient.run(env, [command, env.booksDir.appendingPathComponent(folder).path])
        } catch {
            return error.localizedDescription.nonEmpty ?? Loc.shared.t("check.failed")
        }
        library.reload(env: env, force: true)
        return nil
    }

    // MARK: - Deleting a book

    /// A book that is in the queue (waiting, stopped or running) cannot be deleted under its feet.
    func canDelete(_ folder: String) -> Bool { !books.contains { $0.workdir == folder } }

    func deletionPlan(_ folder: String) -> DeletionPlan {
        DeletionPlan(folder: env.booksDir.appendingPathComponent(folder),
                     others: library.books.filter { $0.folder != folder }.map { env.booksDir.appendingPathComponent($0.folder) })
    }

    /// Moves the book's folder, with everything the app knows about it, to the Trash.
    /// Returns nil when it went, else why not.
    func deleteBook(_ folder: String) -> String? {
        guard canDelete(folder) else { return Loc.shared.t("delete.queued") }
        let url = env.booksDir.appendingPathComponent(folder)
        guard url.deletingLastPathComponent().standardizedFileURL == env.booksDir.standardizedFileURL,
              FileManager.default.fileExists(atPath: url.appendingPathComponent("book.json").path) else {
            return Loc.shared.t("delete.notABook")
        }
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { return error.localizedDescription }
        verified.remove(folder)
        let index = env.booksDir.appendingPathComponent("INDEX.md")
        if let text = try? String(contentsOf: index, encoding: .utf8) {
            let kept = text.components(separatedBy: "\n").filter { !$0.contains("](\(folder)/") }
            try? kept.joined(separator: "\n").write(to: index, atomically: true, encoding: .utf8)
        }
        library.dropCover(folder: folder)
        library.reload(env: env, force: true)
        return nil
    }

    // MARK: - Translation log

    func openLogFolder() {
        try? FileManager.default.createDirectory(at: env.logFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(env.logFolder)
    }

    /// Puts the engine's summary of the log on the clipboard, for the user to read and share.
    func copyLogSummary() async -> Bool {
        guard let data = try? await BackendClient.run(env, ["--log-report"]), !data.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
    }

    // MARK: - Library

    func toggleVerified(_ folder: String) {
        if verified.contains(folder) { verified.remove(folder) } else { verified.insert(folder) }
    }

    /// The metadata "Change" button: set one field of every volume through the engine.
    /// Returns nil when the field was written, else the engine's error text.
    func editMetadata(folder: String, field: String, value: String) async -> String? {
        metadataBusy = true
        defer { metadataBusy = false }
        let folderPath = env.booksDir.appendingPathComponent(folder).path
        do {
            _ = try await BackendClient.run(env, ["--set-metadata", folderPath, "--field", field, "--value", value])
            verified.remove(folder)
            if field == "cover" { library.dropCover(folder: folder) }
            library.reload(env: env, force: true)
            return nil
        } catch {
            let text = error.localizedDescription.isEmpty ? "unknown error" : error.localizedDescription
            lastError = text
            return text
        }
    }

    /// Open every finished volume of a book in the Books app once.
    func addCompletedVolumesToBooks(folder: String) {
        guard addToBooks, let book = LibraryStore.read(folder: env.booksDir.appendingPathComponent(folder)) else { return }
        let books = URL(fileURLWithPath: "/System/Applications/Books.app")
        for volume in book.volumes where volume.status == "completed" && !addedToBooks.contains(volume.output) {
            addedToBooks.insert(volume.output)
            NSWorkspace.shared.open([URL(fileURLWithPath: volume.output)], withApplicationAt: books,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func saveGlossary(for book: QueueBook, decisions: [String: String]) {
        guard let url = file("glossary.json", of: book),
              let data = try? Data(contentsOf: url),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var terms = object["terms"] as? [[String: Any]] else { return }
        for index in terms.indices {
            guard let source = terms[index]["source"] as? String, let decision = decisions[source] else { continue }
            terms[index]["decision"] = decision
        }
        object["terms"] = terms
        if let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? out.write(to: url, options: .atomic)
        }
    }

    // MARK: - Notifications

    func requestNotificationAccess() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ title: String, _ body: String, attention: Bool = true) {
        guard attention ? notifyAttention : notifyVolume, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
