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
    var books: [QueueBook] = [] { didSet { saveQueue() } }
    var engines: [EngineInfo] = []
    var enginesLoading = false
    var paused = false
    var status: EngineStatus?
    var logLine = ""
    var reviewTarget: QueueBook.ID?
    var runningID: QueueBook.ID?
    var lastError = ""
    let library = LibraryStore()

    var quality: String = UserDefaults.standard.string(forKey: "quality") ?? "balanced" {
        didSet { UserDefaults.standard.set(quality, forKey: "quality") }
    }
    var notificationsOn: Bool = UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notificationsOn, forKey: "notifications")
            if notificationsOn { requestNotificationAccess() }
        }
    }

    private var runner: Task<Void, Never>?
    private var current: Process?
    private var killedForPause = false
    private var lastEngineLabel = ""

    init(env: BackendEnvironment = .load()) {
        self.env = env
        loadQueue()
        library.reload(env: env)
        refreshEngines()
    }

    // MARK: - Derived

    var uploaded: [QueueBook] { books.filter { $0.stage == .uploaded || $0.stage == .reading } }
    var readyList: [QueueBook] { books.filter { $0.isQueued } }
    var running: QueueBook? { books.first { $0.id == runningID } }
    var isBusy: Bool { runningID != nil }
    var hasActiveEngine: Bool { engines.contains { $0.active } }
    var waitingCount: Int { books.filter { [.ready, .approved].contains($0.stage) }.count }
    var queueIsClean: Bool { runner == nil && runningID == nil }
    var reviewBooks: [QueueBook] { books.filter { $0.stage == .needsReview } }

    func book(_ id: QueueBook.ID) -> QueueBook? { books.first { $0.id == id } }

    private func update(_ id: QueueBook.ID, _ change: (inout QueueBook) -> Void) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        change(&books[index])
    }

    /// Minutes left for the book that runs now.
    var remainingMinutes: Int? {
        guard let book = running, book.estimatedMinutes > 0, book.volumes > 0 else { return nil }
        let done = Double(max(book.volume - 1, 0) * 100 + book.pct) / Double(book.volumes * 100)
        return max(1, Int(Double(book.estimatedMinutes) * (1 - done)))
    }

    // MARK: - Engines

    func refreshEngines(force: Bool = false) {
        guard !enginesLoading, env.isValid else { return }
        enginesLoading = true
        let env = self.env
        Task {
            let found = try? await BackendClient.detect(env, refresh: force)
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
                let info = try await BackendClient.inspect(env, file: file)
                update(id) {
                    $0.title = info.title; $0.author = info.author; $0.volumes = max(info.volumes, 1)
                    $0.kind = info.kind; $0.estimatedMinutes = info.estimatedMinutes
                    $0.reviewFirst = info.kind == .fiction
                    if $0.stage == .reading { $0.stage = .uploaded }
                }
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
        update(id) { $0.kind = $0.kind.other; $0.reviewFirst = $0.kind == .fiction }
    }

    // MARK: - Queue order

    func makeReady(_ id: QueueBook.ID) {
        update(id) { if $0.stage == .uploaded { $0.stage = .ready } }
        // A book moved into the queue goes to the end of it.
        if let index = books.firstIndex(where: { $0.id == id }) {
            let item = books.remove(at: index)
            books.append(item)
        }
    }

    func makeAllReady() { uploaded.filter { $0.stage == .uploaded }.forEach { makeReady($0.id) } }

    func unready(_ id: QueueBook.ID) {
        guard let book = book(id), book.stage == .ready || book.stage == .failed else { return }
        update(id) { $0.stage = .uploaded; $0.error = "" }
    }

    func moveReady(from: IndexSet, to: Int) {
        var queue = readyList
        queue.move(fromOffsets: from, toOffset: to)
        books = books.filter { !$0.isQueued } + queue
    }

    func moveFirst(_ id: QueueBook.ID) {
        var queue = readyList
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        // The running book keeps the top place.
        let floor = queue.firstIndex { $0.id == runningID }.map { $0 + 1 } ?? 0
        let item = queue.remove(at: index)
        queue.insert(item, at: min(floor, queue.count))
        books = books.filter { !$0.isQueued } + queue
    }

    func setReviewFirst(_ id: QueueBook.ID, _ value: Bool) { update(id) { $0.reviewFirst = value } }

    // MARK: - Running

    func start() {
        paused = false
        guard runner == nil else { return }
        guard env.isValid else { lastError = Loc.shared.t("settings.backendMissing"); return }
        runner = Task { await runLoop(); runner = nil }
    }

    func pause() {
        paused = true
        killedForPause = true
        current?.terminate()
    }

    func resume() { start() }

    func retry(_ id: QueueBook.ID) {
        update(id) { $0.error = ""; $0.stage = $0.workdir == nil ? .ready : .approved }
        start()
    }

    func approve(_ id: QueueBook.ID, style: String) {
        update(id) { $0.style = style; $0.stage = .approved }
        reviewTarget = nil
        start()
    }

    private func nextBook() -> QueueBook? {
        books.first { $0.stage == .ready || $0.stage == .approved }
    }

    private func runLoop() async {
        if engines.isEmpty { engines = (try? await BackendClient.detect(env)) ?? [] }
        guard hasActiveEngine else { lastError = Loc.shared.t("process.noEngine"); return }
        while !paused, let next = nextBook() {
            runningID = next.id
            if next.stage == .ready && next.kind == .fiction && next.reviewFirst && next.workdir == nil {
                await prepare(next)
            } else {
                await translate(next)
            }
            runningID = nil
            status = nil
        }
        runningID = nil
    }

    private func baseArguments(_ book: QueueBook) -> [String] {
        var args = ["--profile", quality, book.kind == .fiction ? "--fiction" : "--non-fiction"]
        if book.style != "auto" { args += ["--style", book.style] }
        return args
    }

    private func inputPath(_ book: QueueBook) -> String {
        guard let workdir = book.workdir else { return env.inbox.appendingPathComponent(book.fileName).path }
        let source = env.booksDir.appendingPathComponent(workdir).appendingPathComponent("source")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: source.path))?.sorted() ?? []
        return files.first.map { source.appendingPathComponent($0).path } ?? source.path
    }

    private func prepare(_ book: QueueBook) async {
        update(book.id) { $0.stage = .preparing; $0.error = "" }
        let before = bookFolders()
        let (code, tail) = await runEngine(["-i", inputPath(book), "--prepare-only"] + baseArguments(book), for: book.id)
        if paused && killedForPause {
            update(book.id) { $0.stage = .ready }
            return
        }
        guard code == 0, let workdir = findWorkdir(for: book, before: before) else {
            fail(book.id, tail)
            return
        }
        update(book.id) { $0.workdir = workdir; $0.stage = .needsReview }
        notify(Loc.shared.t("notify.review", book.title), Loc.shared.t("notify.reviewBody"))
    }

    private func translate(_ book: QueueBook) async {
        update(book.id) { $0.stage = .translating; $0.error = ""; $0.pct = 0; $0.volume = max($0.volume, 0) }
        var args = ["-i", inputPath(book)] + baseArguments(book) + (extraArguments[book.id] ?? [])
        if let workdir = book.workdir {
            args += ["--workdir", env.booksDir.appendingPathComponent(workdir).path]
        }
        let before = bookFolders()
        let (code, tail) = await runEngine(args, for: book.id)
        if killedForPause && paused {
            update(book.id) { $0.stage = $0.workdir == nil ? .ready : .approved }
            return
        }
        let folder = book.workdir ?? findWorkdir(for: book, before: before)
        if code == 0, let folder, let result = LibraryStore.read(folder: env.booksDir.appendingPathComponent(folder)),
           result.isComplete {
            books.removeAll { $0.id == book.id }
            library.reload(env: env)
            notify(Loc.shared.t("notify.done", result.title), Loc.shared.t("notify.doneBody"))
        } else {
            update(book.id) { $0.workdir = $0.workdir ?? folder }
            fail(book.id, tail)
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
            if $0.stage == .translating { $0.volume = status.volume; $0.pct = status.pct; $0.volumes = max(status.volumes, $0.volumes) }
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
        for name in bookFolders() {
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
        guard runner == nil, env.isValid else { return }
        let source = env.booksDir.appendingPathComponent(folder).appendingPathComponent("source")
        guard let first = (try? FileManager.default.contentsOfDirectory(atPath: source.path))?.sorted().first else { return }
        var book = QueueBook(fileName: first, title: library.book(folder: folder)?.title ?? folder)
        book.stage = .approved
        book.workdir = folder
        book.kind = library.book(folder: folder)?.kind ?? .fiction
        book.volumes = library.book(folder: folder)?.volumes.count ?? 1
        books.append(book)
        extraArguments[book.id] = arguments
        start()
    }

    var extraArguments: [QueueBook.ID: [String]] = [:]

    // MARK: - Persistence

    private func saveQueue() {
        guard let data = try? JSONEncoder.pretty.encode(books) else { return }
        try? FileManager.default.createDirectory(at: env.booksDir, withIntermediateDirectories: true)
        try? data.write(to: env.queueFile, options: .atomic)
    }

    private func loadQueue() {
        guard let data = try? Data(contentsOf: env.queueFile),
              var saved = try? JSONDecoder().decode([QueueBook].self, from: data) else { return }
        let fm = FileManager.default
        saved = saved.filter { fm.fileExists(atPath: env.inbox.appendingPathComponent($0.fileName).path) || $0.workdir != nil }
        for index in saved.indices {
            switch saved[index].stage {
            case .reading: saved[index].stage = .uploaded
            case .preparing: saved[index].stage = .ready
            case .translating: saved[index].stage = saved[index].workdir == nil ? .ready : .approved
            default: break
            }
        }
        books = saved
    }

    // MARK: - Notifications

    func requestNotificationAccess() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ title: String, _ body: String) {
        guard notificationsOn, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
