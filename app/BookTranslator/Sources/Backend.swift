import Foundation

/// Where the Python engine and the library are, and how to start the engine.
struct BackendEnvironment {
    var root: URL        // the repo folder that holds translate_book.py
    var booksDir: URL

    var script: URL { root.appendingPathComponent("translate_book.py") }
    var inbox: URL { booksDir.appendingPathComponent("inbox") }
    var statusFile: URL { booksDir.appendingPathComponent("status.json") }
    var queueFile: URL { booksDir.appendingPathComponent(".app-queue.json") }

    var isValid: Bool { FileManager.default.fileExists(atPath: script.path) }

    /// The virtual environment's Python when there is one, else the system one.
    var python: URL {
        for candidate in [".venv/bin/python3", ".venv/bin/python"] {
            let url = root.appendingPathComponent(candidate)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    /// A Mac app does not inherit the shell's PATH, but the engine finds `claude`, `codex`
    /// and `agy` on it. Add the places those tools are normally installed.
    static func searchPath() -> String {
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local",
                     "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.antigravity/bin",
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

    func makeProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = python
        process.currentDirectoryURL = root
        process.arguments = [script.path, "--books-dir", booksDir.path] + arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.cachedPath
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        process.environment = env
        return process
    }

    // MARK: - Locations

    static func defaultRoot() -> URL {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "backendRoot"), !saved.isEmpty { return URL(fileURLWithPath: saved) }
        if let baked = Bundle.main.object(forInfoDictionaryKey: "BTBackendRoot") as? String, !baked.isEmpty {
            return URL(fileURLWithPath: baked).standardizedFileURL
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    static func defaultBooks(root: URL) -> URL {
        if let saved = UserDefaults.standard.string(forKey: "booksDir"), !saved.isEmpty {
            return URL(fileURLWithPath: saved)
        }
        return root.appendingPathComponent("books")
    }

    static func load() -> BackendEnvironment {
        let root = defaultRoot()
        return BackendEnvironment(root: root, booksDir: defaultBooks(root: root))
    }
}

struct BackendError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Runs the engine for the quick, one-shot calls (`--detect`, `--inspect`).
enum BackendClient {
    static func run(_ env: BackendEnvironment, _ arguments: [String]) async throws -> Data {
        guard env.isValid else { throw BackendError(message: "translate_book.py not found in \(env.root.path)") }
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

    static func inspect(_ env: BackendEnvironment, file: URL) async throws -> InspectResult {
        let data = try await run(env, ["--inspect", file.path])
        return try JSONDecoder.snake.decode(InspectResult.self, from: lastJSON(data))
    }

    /// stdout may carry log lines before the JSON; the JSON is the last line.
    static func lastJSON(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        let line = text.split(separator: "\n").last { $0.hasPrefix("{") || $0.hasPrefix("[") }
        return Data((line.map(String.init) ?? text).utf8)
    }
}
