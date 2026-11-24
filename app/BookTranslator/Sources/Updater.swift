import Foundation
import Observation
import AppKit

/// Checks a release feed and installs a newer build of the app.
///
/// The feed is the latest-release JSON of the project's GitHub repository: `tag_name` is the
/// version, `body` the notes and an asset ending in `.zip` holds the app. The install never
/// runs while a translation is running: it waits for the queue to be empty.
@MainActor @Observable
final class Updater {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case downloading
        case failed(String)
    }

    struct Release: Equatable {
        var version: String
        var notes: String
        var url: URL
    }

    var state: State = .idle
    var autoUpdate: Bool = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate") }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    private var feed: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "BTUpdateFeed") as? String).flatMap(URL.init(string:))
    }

    // MARK: - Version logic

    /// True when `candidate` is a higher dotted version than `current` ("v1.10" > "1.9").
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    nonisolated static func parseRelease(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = assets.compactMap { $0["browser_download_url"] as? String }.first { $0.hasSuffix(".zip") }
        guard let link = zip.flatMap(URL.init(string:)) else { return nil }
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                       notes: json["body"] as? String ?? "", url: link)
    }

    // MARK: - Checking

    func check() async {
        guard let feed else { state = .failed("no feed"); return }
        state = .checking
        do {
            var request = URLRequest(url: feed, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                state = .failed("HTTP \(http.statusCode)")
                return
            }
            guard let release = Updater.parseRelease(data) else { state = .upToDate; return }
            state = Updater.isNewer(release.version, than: Updater.currentVersion) ? .available(release) : .upToDate
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Called when the queue becomes idle or at launch: installs a waiting update if allowed.
    func installIfAllowed(queueIdle: Bool) async {
        guard autoUpdate, queueIdle, case .available = state else { return }
        await install()
    }

    // MARK: - Installing

    func install() async {
        guard case .available(let release) = state else { return }
        state = .downloading
        do {
            let (zip, _) = try await URLSession.shared.download(from: release.url)
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("bt-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let unpack = Process()
            unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unpack.arguments = ["-x", "-k", zip.path, work.path]
            try unpack.run(); unpack.waitUntilExit()
            guard unpack.terminationStatus == 0,
                  let app = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }) else {
                state = .failed("bad archive"); return
            }
            try Updater.replaceAndRelaunch(newApp: app)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Hands the swap to a small shell script that waits for this process to quit.
    private static func replaceAndRelaunch(newApp: URL) throws {
        let target = Bundle.main.bundleURL
        let script = """
        #!/bin/zsh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.5; done
        rm -rf \(shellQuote(target.path))
        ditto \(shellQuote(newApp.path)) \(shellQuote(target.path))
        open \(shellQuote(target.path))
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bt-update.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [file.path]
        try process.run()
        NSApp.terminate(nil)
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
