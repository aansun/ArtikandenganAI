import Foundation

/// Where the Python engine and the library are, and how to start the engine.
struct BackendEnvironment {
    var root: URL        // the folder that holds translate_book.py (the app's own copy, or a developer's repo)
    var booksDir: URL
    var engineOrder: [String] = []
    /// The user's own model per engine; an engine not named here uses the recommended one.
    var engineModels: [String: String] = [:]
    /// The Python to run (the app's own environment); nil means the repo's `.venv`, else the system one.
    var pythonOverride: URL?
    /// Where processes run. The built-in engine lives inside the app bundle, which must stay untouched.
    var workDir: URL?
    /// True when the engine is the copy built into the app rather than a folder the user chose.
    var isBuiltIn = false

    var script: URL { root.appendingPathComponent("translate_book.py") }
    var inbox: URL { booksDir.appendingPathComponent("inbox") }
    var logFolder: URL { booksDir.appendingPathComponent("_activity-log") }
    var statusFile: URL { booksDir.appendingPathComponent("status.json") }
    var queueFile: URL { booksDir.appendingPathComponent(".app-queue.json") }

    var isValid: Bool { FileManager.default.fileExists(atPath: script.path) }
    /// The engine is there and so is a Python to run it with.
    var isReady: Bool { isValid && FileManager.default.isExecutableFile(atPath: python.path) }

    /// The virtual environment's Python when there is one, else the system one.
    var python: URL {
        if let pythonOverride { return pythonOverride }
        for candidate in [".venv/bin/python3", ".venv/bin/python"] {
            let url = root.appendingPathComponent(candidate)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    /// A Mac app does not inherit the shell's PATH, but the engine finds `claude`, `codex`,
    /// `agy` and `opencode` on it. Add the places those tools are normally installed.
    static func searchPath() -> String {
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local",
                     "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.antigravity/bin", "\(home)/.opencode/bin",
                     "/usr/bin", "/bin"]
        let current = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (extra + current + loginShellPath()).filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    private static func loginShellPath() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(separator: ":").map(String.init)
    }

    static let cachedPath = searchPath()

    /// The engine's local activity log is on until the user switches it off. Read for every run.
    static var keepsLog: Bool { UserDefaults.standard.object(forKey: "keepLog") as? Bool ?? true }

    func makeProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = python
        process.currentDirectoryURL = workDir ?? root
        let order = EngineInfo.completeOrder(engineOrder)
        let engines = order.isEmpty ? [] : ["--engines", order.joined(separator: ",")]
        let models = engineModels.sorted { $0.key < $1.key }.flatMap { ["--engine-model", "\($0.key)=\($0.value)"] }
        let log = Self.keepsLog ? [] : ["--no-log"]
        process.arguments = [script.path, "--books-dir", booksDir.path] + engines + models + log + arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.cachedPath
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONDONTWRITEBYTECODE"] = "1"                 // never write into the (signed) app bundle
        env["NNAI_APP_VERSION"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        if env["ATTRIBUTION_ENABLED"] == nil { env["ATTRIBUTION_ENABLED"] = "false" }   // no translator signature in results
        process.environment = env
        return process
    }

    // MARK: - Locations

    /// The engine copy inside the app (Contents/Resources/engine), when this build has one.
    static var bundledEngine: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("engine"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("translate_book.py").path) else { return nil }
        return url
    }

    /// The developer's repository baked in at build time. A plain URL: no file access happens here, because
    /// touching Documents, Desktop or iCloud Drive can raise macOS's folder-access prompt, which blocks the
    /// calling thread until it is answered. Launch must never wait on that.
    static var bakedRoot: URL? {
        guard let baked = Bundle.main.object(forInfoDictionaryKey: "BTBackendRoot") as? String, !baked.isEmpty else { return nil }
        return URL(fileURLWithPath: baked).standardizedFileURL
    }

    static var savedRoot: URL? {
        guard let saved = UserDefaults.standard.string(forKey: "backendRoot"), !saved.isEmpty else { return nil }
        return URL(fileURLWithPath: saved)
    }

    /// The library folder: the one chosen in Settings, else ~/Documents/NNAI Translator. (No file access.)
    static func defaultBooks() -> URL {
        if let saved = UserDefaults.standard.string(forKey: "booksDir"), !saved.isEmpty { return URL(fileURLWithPath: saved) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/NNAI Translator")
    }

    /// A library that already holds books, left in the repository's `books/` from before the engine moved into
    /// the app. Reads the disk, so call it off the main thread, and only while no library folder is chosen.
    static func legacyLibrary() -> URL? {
        guard UserDefaults.standard.string(forKey: "booksDir")?.isEmpty ?? true,
              let legacy = bakedRoot?.appendingPathComponent("books"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: legacy.path),
              names.contains(where: { FileManager.default.fileExists(atPath: legacy.appendingPathComponent($0).appendingPathComponent("book.json").path) })
        else { return nil }
        return legacy
    }

    /// 1) a folder the user chose in Settings, 2) the engine built into the app, 3) the repository it was built from.
    static func load() -> BackendEnvironment {
        if let saved = savedRoot {
            return BackendEnvironment(root: saved, booksDir: defaultBooks())
        }
        if let bundled = bundledEngine {
            var env = BackendEnvironment(root: bundled, booksDir: defaultBooks())
            env.pythonOverride = EngineSetup.pythonExecutable
            env.workDir = EngineSetup.defaultSupportDir
            env.isBuiltIn = true
            return env
        }
        let root = bakedRoot ?? URL(fileURLWithPath: NSHomeDirectory())
        return BackendEnvironment(root: root, booksDir: root.appendingPathComponent("books"))
    }
}

struct BackendError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Runs the engine for the quick, one-shot calls (`--detect`, `--inspect`).
enum BackendClient {
    static func run(_ env: BackendEnvironment, _ arguments: [String]) async throws -> Data {
        guard env.isReady else { throw BackendError(message: "the translation engine is not ready (\(env.root.path))") }
        return try await withCheckedThrowingContinuation { continuation in
            let process = env.makeProcess(arguments)
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { finished in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    let text = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: BackendError(message: String(text.suffix(400))))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    static func detect(_ env: BackendEnvironment, refresh: Bool = false) async throws -> [EngineInfo] {
        let data = try await run(env, ["--detect"] + (refresh ? ["--refresh-engines"] : []))
        return try JSONDecoder().decode([EngineInfo].self, from: lastJSON(data))
    }

    /// A Kindle command. Its answer is read whether it succeeded or not; `secrets` goes into the
    /// environment of this one process.
    static func kindle(_ env: BackendEnvironment, _ arguments: [String], secrets: [String: String] = [:]) async throws -> KindleAnswer {
        guard env.isReady else { throw BackendError(message: "the translation engine is not ready (\(env.root.path))") }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let process = env.makeProcess(arguments)
            process.environment = (process.environment ?? [:]).merging(secrets) { _, new in new }
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            process.terminationHandler = { _ in continuation.resume(returning: out.fileHandleForReading.readDataToEndOfFile()) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        return try JSONDecoder.snake.decode(KindleAnswer.self, from: lastJSON(data))
    }

    /// An e-ink reader command. Its answer is read whether it succeeded or not.
    static func xteink(_ env: BackendEnvironment, _ arguments: [String]) async throws -> XteinkAnswer {
        guard env.isReady else { throw BackendError(message: "the translation engine is not ready (\(env.root.path))") }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let process = env.makeProcess(arguments)
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            process.terminationHandler = { _ in continuation.resume(returning: out.fileHandleForReading.readDataToEndOfFile()) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        return try JSONDecoder.snake.decode(XteinkAnswer.self, from: lastJSON(data))
    }

    static func modelChoices(_ env: BackendEnvironment) async throws -> [String: ModelChoices] {
        let data = try await run(env, ["--list-models"])
        return try JSONDecoder().decode([String: ModelChoices].self, from: lastJSON(data))
    }

    static func inspect(_ env: BackendEnvironment, file: URL, target: String = "Indonesian") async throws -> InspectResult {
        let data = try await run(env, ["--inspect", file.path, "-tl", target])
        return try JSONDecoder.snake.decode(InspectResult.self, from: lastJSON(data))
    }

    /// stdout may carry log lines before the JSON; the JSON is the last line.
    static func lastJSON(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        let line = text.split(separator: "\n").last { $0.hasPrefix("{") || $0.hasPrefix("[") }
        return Data((line.map(String.init) ?? text).utf8)
    }
}
