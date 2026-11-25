import Foundation
import Observation
import CryptoKit

/// Prepares the Python environment the built-in engine runs in: finds a Python 3.10 or newer, makes a
/// virtual environment in Application Support and installs the engine's requirements into it. This needs
/// the internet once; afterwards the engine runs offline apart from the translation CLIs themselves.
@MainActor @Observable
final class EngineSetup {
    enum State: Equatable {
        case unknown, ready, needsSetup, working, noPython, failed(String)
    }

    var state: State = .unknown
    var progress = ""          // the last thing pip said
    var stepsDone = 0

    let supportDir: URL
    static let minimumPython = (3, 10)

    init(supportDir: URL = EngineSetup.defaultSupportDir) { self.supportDir = supportDir }

    nonisolated static var defaultSupportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NNAI Translator")
    }
    nonisolated static var pythonExecutable: URL { pythonExecutable(in: defaultSupportDir) }
    nonisolated static func pythonExecutable(in support: URL) -> URL {
        support.appendingPathComponent("python-env/bin/python3")
    }

    var venv: URL { supportDir.appendingPathComponent("python-env") }
    var python: URL { Self.pythonExecutable(in: supportDir) }
    private var marker: URL { venv.appendingPathComponent(".bt-ready") }

    // MARK: - State

    /// What the environment must match: the requirements file of this build of the engine.
    nonisolated static func stamp(engine: URL) -> String {
        let data = (try? Data(contentsOf: engine.appendingPathComponent("requirements.txt"))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func check(engine: URL) {
        let current = Self.stamp(engine: engine)
        let saved = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        state = (saved == current && FileManager.default.isExecutableFile(atPath: python.path)) ? .ready : .needsSetup
    }

    // MARK: - Python discovery

    /// "3.13" -> (3, 13); nil for anything else.
    nonisolated static func parseVersion(_ text: String) -> (Int, Int)? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        return (major, minor)
    }

    nonisolated static func isSuitable(_ version: (Int, Int)) -> Bool {
        version.0 > minimumPython.0 || (version.0 == minimumPython.0 && version.1 >= minimumPython.1)
    }

    nonisolated static var pythonCandidates: [String] {
        var list: [String] = []
        for minor in stride(from: 14, through: 10, by: -1) {
            for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/Library/Frameworks/Python.framework/Versions/3.\(minor)/bin"] {
                list.append("\(dir)/python3.\(minor)")
            }
        }
        list += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        return list
    }

    /// The first installed Python that is new enough.
    nonisolated static func findPython() async -> URL? {
        for path in pythonCandidates where FileManager.default.isExecutableFile(atPath: path) {
            let out = LineBox()
            let code = await run(URL(fileURLWithPath: path), ["-c", "import sys; print('%d.%d' % sys.version_info[:2])"], cwd: nil, onLine: out.add)
            if code == 0, let v = parseVersion(out.joined), isSuitable(v) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    // MARK: - Install

    func install(engine: URL) async {
        guard state != .working else { return }
        state = .working
        progress = ""
        stepsDone = 0
        guard let base = await Self.findPython() else { state = .noPython; return }
        do {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: venv)

            progress = "python -m venv"
            let tail = LineBox()
            var code = await Self.run(base, ["-m", "venv", venv.path], cwd: supportDir, onLine: tail.add)
            guard code == 0 else { throw SetupError("could not create the Python environment: \(tail.last)") }

            let pip = LineBox()
            code = await Self.run(python, ["-m", "pip", "install", "--disable-pip-version-check", "--no-input",
                                           "-r", engine.appendingPathComponent("requirements.txt").path],
                                  cwd: supportDir) { [weak self] line in
                pip.add(line)
                Task { @MainActor in
                    guard let self else { return }
                    if line.hasPrefix("Collecting") || line.hasPrefix("Installing") || line.hasPrefix("Downloading") {
                        self.stepsDone += line.hasPrefix("Collecting") ? 1 : 0
                        self.progress = line
                    }
                }
            }
            guard code == 0 else { throw SetupError("installing the engine's libraries failed: \(pip.last)") }

            // The engine must start with them, and carry every module a real run imports (--help would not notice
            // a missing one: that is how a packaged engine once failed on its first book).
            let check = LineBox()
            code = await Self.run(python, [engine.appendingPathComponent("translate_book.py").path, "--selfcheck"], cwd: supportDir, onLine: check.add)
            guard code == 0 else { throw SetupError("the engine did not start: \(check.last)") }

            try Self.stamp(engine: engine).write(to: marker, atomically: true, encoding: .utf8)
            state = .ready
        } catch {
            state = .failed(String(error.localizedDescription.suffix(300)))
        }
    }

    struct SetupError: LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: - Process helper

    final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var joined: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
        var last: String { lock.lock(); defer { lock.unlock() }; return lines.last(where: { !$0.isEmpty }) ?? "" }
    }

    /// Runs a program to the end, feeding its output lines to ``onLine``; returns the exit code.
    nonisolated static func run(_ exe: URL, _ args: [String], cwd: URL?, onLine: @escaping @Sendable (String) -> Void) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = exe
            process.arguments = args
            process.currentDirectoryURL = cwd
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = BackendEnvironment.cachedPath
            env["PIP_NO_INPUT"] = "1"
            env["PYTHONDONTWRITEBYTECODE"] = "1"      // the verification run must not write into the app bundle
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let buffer = LineBox()
            var pending = ""
            let lock = NSLock()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                lock.lock()
                pending += String(decoding: data, as: UTF8.self)
                var lines: [String] = []
                while let newline = pending.firstIndex(of: "\n") {
                    lines.append(String(pending[..<newline]))
                    pending.removeSubrange(...newline)
                }
                lock.unlock()
                lines.forEach { buffer.add($0); onLine($0) }
            }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                lock.lock(); let rest = pending; lock.unlock()
                if !rest.isEmpty { onLine(rest) }
                continuation.resume(returning: finished.terminationStatus)
            }
            do { try process.run() } catch { onLine(error.localizedDescription); continuation.resume(returning: -1) }
        }
    }
}
