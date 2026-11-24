import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    @Environment(Updater.self) private var updater

    var body: some View {
        @Bindable var model = model
        @Bindable var loc = loc
        @Bindable var updater = updater
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionTitle(text: loc.t("nav.settings"))
                if !model.env.isValid { backendWarning }

                group(loc.t("settings.language"), hint: loc.t("settings.languageHint")) {
                    Picker("", selection: $loc.language) {
                        ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                }

                group(loc.t("settings.version")) { versionBlock(updater: updater) }

                group(loc.t("settings.engines"), hint: loc.t("settings.enginesHint")) { enginesBlock }

                group(loc.t("settings.quality"), hint: loc.t("settings.qualityHint")) {
                    Picker("", selection: $model.quality) {
                        ForEach(["economy", "balanced", "best"], id: \.self) { Text(loc.t("settings.q.\($0)")).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
                }

                group(loc.t("settings.folder")) {
                    pathRow(model.env.booksDir) { url in
                        UserDefaults.standard.set(url.path, forKey: "booksDir")
                        model.env.booksDir = url
                        model.library.reload(env: model.env)
                    }
                }

                group(loc.t("settings.backend")) {
                    pathRow(model.env.root) { url in
                        UserDefaults.standard.set(url.path, forKey: "backendRoot")
                        model.env.root = url
                        model.refreshEngines(force: true)
                    }
                }

                group(loc.t("settings.notifications"), hint: loc.t("settings.notificationsHint")) {
                    Toggle("", isOn: $model.notificationsOn).labelsHidden()
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var backendWarning: some View {
        Label(loc.t("settings.backendMissing"), systemImage: "exclamationmark.triangle.fill")
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Theme.warnText).background(Theme.warnBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    private func group<Content: View>(_ title: String, hint: String = "", @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if !hint.isEmpty { Text(hint).font(.caption).foregroundStyle(.secondary) }
            content()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.10)))
    }

    // MARK: - Version

    @ViewBuilder private func versionBlock(updater: Updater) -> some View {
        @Bindable var updater = updater
        HStack {
            Text(loc.t("settings.versionNow", Updater.currentVersion, Updater.currentBuild)).font(.body.weight(.medium))
            Spacer()
            Button(updater.state == .checking ? loc.t("settings.checking") : loc.t("settings.check")) {
                Task { await updater.check() }
            }.disabled(updater.state == .checking || updater.state == .downloading)
        }
        switch updater.state {
        case .upToDate: Label(loc.t("settings.upToDate"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Text(loc.t("settings.updateFailed", message)).font(.caption).foregroundStyle(.secondary)
        case .downloading: HStack { ProgressView().controlSize(.small); Text(loc.t("settings.installing")) }
        case .available(let release):
            VStack(alignment: .leading, spacing: 8) {
                Text(loc.t("settings.available", release.version)).font(.body.weight(.semibold))
                if !release.notes.isEmpty { Text(release.notes).font(.callout).foregroundStyle(.secondary).lineLimit(6) }
                if model.isBusy {
                    Text(loc.t("settings.waitIdle")).font(.caption).foregroundStyle(Theme.warnText)
                } else {
                    Button(loc.t("settings.install")) { Task { await updater.install() } }.buttonStyle(.borderedProminent)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        default: EmptyView()
        }
        Divider()
        Toggle(loc.t("settings.auto"), isOn: $updater.autoUpdate)
        Text(loc.t("settings.autoHint")).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - Engines

    private var enginesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.enginesLoading && model.engines.isEmpty {
                HStack { ProgressView().controlSize(.small); Text(loc.t("settings.detecting")) }
            }
            ForEach(model.engines) { engine in
                HStack(alignment: .top) {
                    Image(systemName: engine.active ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(engine.active ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.label).font(.body.weight(.medium))
                        if !engine.active { Text(engine.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    if engine.role == "main" { Chip(text: loc.t("settings.main"), tint: Theme.accent) }
                    else if engine.role == "backup" { Chip(text: loc.t("settings.backup")) }
                    else { Chip(text: loc.t("settings.inactive")) }
                }
            }
            Button(loc.t("settings.recheck")) { model.refreshEngines(force: true) }.disabled(model.enginesLoading)
        }
    }

    private func pathRow(_ url: URL, choose: @escaping (URL) -> Void) -> some View {
        HStack {
            Text(url.path).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(loc.t("settings.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button(loc.t("settings.choose")) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.directoryURL = url
                if panel.runModal() == .OK, let picked = panel.url { choose(picked) }
            }
        }
    }
}
