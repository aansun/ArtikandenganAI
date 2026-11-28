import SwiftUI
import CryptoKit

/// The mail server the sender's address belongs to.
enum KindleServer: String, CaseIterable, Identifiable {
    case gmail, icloud, yahoo, other
    var id: String { rawValue }
    var host: String {
        switch self {
        case .gmail: return "smtp.gmail.com"
        case .icloud: return "smtp.mail.me.com"
        case .yahoo: return "smtp.mail.yahoo.com"
        case .other: return ""
        }
    }
    var port: Int { self == .yahoo ? 465 : 587 }
    var label: String { self == .gmail ? "Gmail" : (self == .icloud ? "iCloud" : (self == .yahoo ? "Yahoo" : "")) }
}

/// What Settings knows about sending to a Kindle. The password is not here: it stays in the Keychain.
struct KindleSettings: Equatable {
    var to = ""
    var from = ""
    var server = KindleServer.gmail
    var customHost = ""
    var customPort = "587"
    var user = ""

    static let domains = ["kindle.com", "free.kindle.com", "kindle.cn"]
    var host: String { server == .other ? customHost.trimmed : server.host }
    var port: String { server == .other ? customPort.trimmed : "\(server.port)" }

    var toLooksRight: Bool {
        let parts = to.trimmed.split(separator: "@")
        return parts.count == 2 && Self.domains.contains(parts[1].lowercased())
    }
    var fromLooksRight: Bool {
        let parts = from.trimmed.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".")
    }
    /// Everything but the password is filled in.
    var isComplete: Bool { toLooksRight && fromLooksRight && !host.isEmpty && Int(port) != nil }

    /// The engine reads its settings from the environment, never from the command line.
    func environment(password: String) -> [String: String] {
        ["KINDLE_TO": to.trimmed, "KINDLE_FROM": from.trimmed, "KINDLE_SMTP_HOST": host, "KINDLE_SMTP_PORT": port,
         "KINDLE_SMTP_USER": server == .other ? user.trimmed : "",
         // an app password is shown in groups of four; the spaces are not part of it
         "KINDLE_SMTP_PASSWORD": server == .gmail ? password.components(separatedBy: .whitespacesAndNewlines).joined()
                                                  : password]
    }

    static func load(_ defaults: UserDefaults = .standard) -> KindleSettings {
        let saved = defaults.dictionary(forKey: "kindle") as? [String: String] ?? [:]
        return KindleSettings(to: saved["to"] ?? "", from: saved["from"] ?? "",
                              server: KindleServer(rawValue: saved["server"] ?? "") ?? .gmail,
                              customHost: saved["host"] ?? "", customPort: saved["port"] ?? "587", user: saved["user"] ?? "")
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(["to": to, "from": from, "server": server.rawValue, "host": customHost, "port": customPort,
                      "user": user], forKey: "kindle")
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// One finished volume as `translate_book.py --kindle-check` reports it.
struct KindleFile: Codable, Identifiable, Equatable {
    var volume: Int
    var title: String
    var author: String
    var language: String
    var cover: Bool
    var series: String
    var bytes: Int
    var problems: [String]
    var state: String              // "new", "sent" or "changed" since it was sent
    var sentAt: String
    var blocked: Bool
    var id: Int { volume }
    /// The problems that stop a file from being sent (the same list the engine holds).
    static let blockingProblems = ["unreadable", "too_large", "title", "author", "author_email", "language"]
}

struct KindleResult: Codable, Equatable {
    var volume: Int
    var result: String             // "sent", "already", "blocked" or "failed"
    var detail: String
}

/// What the engine answers to `--kindle-send` and `--kindle-test`, and to a check that failed.
struct KindleAnswer: Codable, Equatable {
    var ok: Bool?
    var error: String?
    var detail: String?
    var results: [KindleResult]?
    var files: [KindleFile]?
}

/// Whether the files of a library book are on the Kindle, for its mark in the library.
enum KindleMark: Equatable {
    case none, sent, changed

    private struct Record: Codable {
        struct Entry: Codable { var volume: Int; var sha256: String }
        var sent: [Entry]
    }

    /// `sent`: every finished volume is there as it is now. `changed`: one was sent and is different now.
    /// Reads the files only for a book that was sent at least once.
    static func of(folder: URL, volumes: [VolumeInfo]) -> KindleMark {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("kindle.json")),
              let record = try? JSONDecoder().decode(Record.self, from: data), !record.sent.isEmpty else { return .none }
        var all = true
        for volume in volumes where volume.status == "completed" {
            let mine = record.sent.filter { $0.volume == volume.index }
            guard !mine.isEmpty else { all = false; continue }
            guard let file = try? Data(contentsOf: URL(fileURLWithPath: volume.output)) else { all = false; continue }
            let now = SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
            if !mine.contains(where: { $0.sha256 == now }) { return .changed }
        }
        return all ? .sent : .none
    }
}

/// On a book's page: what the Kindle will read from each file, whether it was sent, and the button to send it.
struct KindleCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    @Environment(\.openSettings) private var openSettings
    var book: LibraryBook
    @State private var files: [KindleFile] = []
    @State private var message = ""
    @State private var failed = false
    @State private var asking: KindleFile?

    /// The card reads the files again when one of them changes.
    private var revision: String {
        book.folder + book.volumes.map { volume in
            let date = (try? FileManager.default.attributesOfItem(atPath: volume.output))?[.modificationDate] as? Date
            return "\(date?.timeIntervalSince1970 ?? 0)"
        }.joined()
    }

    var body: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "paperplane.fill").foregroundStyle(Theme.accent)
                    Text(loc.t("kindle.title")).font(.system(size: 13, weight: .semibold))
                }
                ForEach(files) { row($0) }
                if !model.kindleReady {
                    Text(loc.t("kindle.setUp")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(loc.t("kindle.openSettings")) { openSettings() }
                        .buttonStyle(PrimaryButtonStyle(radius: 8, vertical: 5, horizontal: 12, size: 12.5))
                }
                if !message.isEmpty {
                    Text(message).font(.system(size: 11)).foregroundStyle(failed ? Theme.danger : Theme.okText)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: revision) { await reload() }
        .confirmationDialog(asking.map { loc.t($0.state == "sent" ? "kindle.confirmAgain" : "kindle.confirm", $0.title) } ?? "",
                            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            presenting: asking) { file in
            Button(loc.t(file.state == "new" ? "kindle.send" : "kindle.resend")) { send(file) }
            Button(loc.t("common.cancel"), role: .cancel) {}
        } message: { file in
            Text(loc.t("kindle.confirmDetails", file.title, file.author, file.language,
                       loc.t(file.cover ? "meta.attached" : "meta.missing"), model.kindle.to))
        }
    }

    private func row(_ file: KindleFile) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if files.count > 1 { Text(loc.t("detail.volumeN", file.volume)).font(.system(size: 12, weight: .semibold)) }
                state(file).fixedSize()
                Spacer(minLength: 4)
                Button(model.kindleSending == "\(book.folder)#\(file.volume)" ? loc.t("kindle.sending")
                       : loc.t(file.state == "new" ? "kindle.send" : "kindle.resend")) { asking = file }
                    .buttonStyle(PrimaryButtonStyle(radius: 8, fill: file.state == "sent" ? Theme.actionNonfiction : Theme.accent,
                                                    vertical: 4, horizontal: 10, size: 12))
                    .disabled(file.blocked || !model.kindleReady || model.kindleSending != nil)
                    .opacity(file.blocked || !model.kindleReady ? 0.4 : 1)
            }
            Text("\(file.title.isEmpty ? "—" : file.title) · \(file.author.isEmpty ? "—" : file.author) · \(file.language.isEmpty ? "—" : file.language)")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
            ForEach(file.problems.filter { Loc.table["kindle.problem.\($0)"] != nil }, id: \.self) { problem in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: KindleFile.blockingProblems.contains(problem) ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    Text(loc.t("kindle.problem.\(problem)")).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
                .foregroundStyle(KindleFile.blockingProblems.contains(problem) ? Theme.danger : Theme.warnIcon)
            }
        }
    }

    @ViewBuilder private func state(_ file: KindleFile) -> some View {
        switch file.state {
        case "sent": Pill(text: loc.t("kindle.sentOn", Self.day(file.sentAt, loc)), bg: Theme.okBg, fg: Theme.okText, size: 11)
        case "changed": Pill(text: loc.t("kindle.changed"), bg: Theme.warnBg, fg: Theme.warnText, size: 11)
        default: Pill(text: loc.t("kindle.new"), bg: Theme.neutralBg, fg: Theme.neutralText, size: 11)
        }
    }

    /// The day a file was sent, short, in the app's language.
    static func day(_ stamp: String, _ loc: Loc) -> String {
        guard let date = ISO8601DateFormatter().date(from: stamp) else { return "" }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: loc.language == .id ? "id_ID" : "en_US")))
    }

    private func reload() async {
        files = await model.kindleFiles(book.folder)
    }

    private func send(_ file: KindleFile) {
        message = ""
        Task {
            let outcome = await model.sendToKindle(book.folder, volume: file.volume, resend: file.state == "sent")
            (message, failed) = (outcome.text, !outcome.ok)
            await reload()
        }
    }
}
