import SwiftUI

/// Where the e-ink reader is and how books go to it. Nothing here is secret.
struct XteinkSettings: Equatable {
    static let defaultAddress = "crosspoint.local"
    static let defaultFolder = "/Books"

    var address = ""                // empty: the default name
    var folder = ""
    var prepare = true              // pictures and fonts made to suit the screen

    var usedAddress: String { Self.trim(address).isEmpty ? Self.defaultAddress : Self.trim(address) }
    var usedFolder: String { Self.trim(folder).isEmpty ? Self.defaultFolder : Self.trim(folder) }
    /// The reader's own web page, to open in a browser.
    var webPage: URL? {
        let host = usedAddress.replacingOccurrences(of: "http://", with: "", options: .caseInsensitive)
        return URL(string: "http://\(host)")
    }
    var arguments: [String] {
        ["--xteink-address", usedAddress, "--xteink-folder", usedFolder] + (prepare ? [] : ["--xteink-as-is"])
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func load(_ defaults: UserDefaults = .standard) -> XteinkSettings {
        let saved = defaults.dictionary(forKey: "xteink") as? [String: String] ?? [:]
        return XteinkSettings(address: saved["address"] ?? "", folder: saved["folder"] ?? "", prepare: saved["prepare"] != "no")
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(["address": address, "folder": folder, "prepare": prepare ? "yes" : "no"], forKey: "xteink")
    }
}

/// One finished volume as `translate_book.py --xteink-check` reports it.
struct XteinkFile: Codable, Identifiable, Equatable {
    var volume: Int
    var state: String              // "new", "sent" or "changed" since it was sent
    var sentAt: String
    var id: Int { volume }
}

/// What the engine answers to `--xteink-check`, `--xteink-send` and `--xteink-test`.
struct XteinkAnswer: Codable, Equatable {
    var ok: Bool?
    var error: String?
    var detail: String?
    var device: String?
    var version: String?
    var results: [KindleResult]?
    var files: [XteinkFile]?
}

/// The reader's row of a book's page: whether each volume is there, and the button to send it.
struct XteinkRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    var book: LibraryBook
    @State private var files: [XteinkFile] = []
    @State private var message = ""
    @State private var failed = false
    @State private var replacing: XteinkFile?      // the reader holds a file of this name already

    private var revision: String {
        book.folder + book.volumes.map { volume in
            let date = (try? FileManager.default.attributesOfItem(atPath: volume.output))?[.modificationDate] as? Date
            return "\(date?.timeIntervalSince1970 ?? 0)"
        }.joined()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ActionIcon(symbol: "ipad")
                Text("Xteink").font(.system(size: 13)).foregroundStyle(Theme.ink).fixedSize().help(loc.t("xteink.title"))
                Spacer(minLength: 4)
                if files.count == 1, let file = files.first {
                    state(file).fixedSize()
                    sendButton(file)
                }
            }
            if files.count > 1 {
                ForEach(files) { file in
                    HStack(spacing: 6) {
                        Text(loc.t("detail.volumeN", file.volume)).font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 4)
                        state(file).fixedSize()
                        sendButton(file)
                    }
                }
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 11)).foregroundStyle(failed ? Theme.danger : Theme.okText)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
        .task(id: revision) { files = await model.xteinkFiles(book.folder) }
        .confirmationDialog(loc.t("xteink.replaceAsk"),
                            isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
                            presenting: replacing) { file in
            Button(loc.t("xteink.replace"), role: .destructive) { send(file, resend: true) }
            Button(loc.t("common.cancel"), role: .cancel) {}
        } message: { _ in
            Text(loc.t("xteink.replaceDetails", model.xteink.usedFolder))
        }
    }

    private func sendButton(_ file: XteinkFile) -> some View {
        let sending = model.xteinkSending == "\(book.folder)#\(file.volume)"
        let words = loc.t(sending ? "kindle.sending" : (file.state == "new" ? "kindle.send" : "kindle.resend"))
        return ToolButton(symbol: sending ? "hourglass" : (file.state == "sent" ? "arrow.clockwise" : "paperplane.fill"),
                          help: "\(words): \(model.xteink.usedAddress)\(model.xteink.usedFolder)", tint: Theme.accent,
                          fill: file.state == "sent" ? nil : Theme.accent) { send(file, resend: file.state == "sent") }
            .disabled(model.xteinkSending != nil || !model.env.isReady)
    }

    @ViewBuilder private func state(_ file: XteinkFile) -> some View {
        switch file.state {
        case "sent": Pill(text: loc.t("kindle.sentOn", KindleCard.day(file.sentAt, loc)), bg: Theme.okBg, fg: Theme.okText, size: 11)
        case "changed": Pill(text: loc.t("kindle.changed"), bg: Theme.warnBg, fg: Theme.warnText, size: 11)
        default: Pill(text: loc.t("kindle.new"), bg: Theme.neutralBg, fg: Theme.neutralText, size: 11)
        }
    }

    private func send(_ file: XteinkFile, resend: Bool) {
        message = ""
        Task {
            let outcome = await model.sendToXteink(book.folder, volume: file.volume, resend: resend)
            if outcome.exists { replacing = file } else { (message, failed) = (outcome.text, !outcome.ok) }
            files = await model.xteinkFiles(book.folder)
        }
    }
}
