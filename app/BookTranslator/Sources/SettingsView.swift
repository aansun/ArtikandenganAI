import SwiftUI

/// Settings, as in the design: grouped white cards of rows (title and hint left, control right).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    @Environment(Updater.self) private var updater
    @Environment(AppearanceStore.self) private var appearance
    @State private var apiKey = ""
    @State private var summaryCopied: Bool?
    @State private var kindlePassword = ""
    @State private var kindleTest: (ok: Bool, text: String)?
    @State private var kindleTesting = false
    var height: CGFloat = 820            // the window scrolls; the screen tests render it whole
    @State private var keyStored = !Secrets.googleBooksKey.isEmpty

    var body: some View {
        @Bindable var model = model
        @Bindable var updater = updater
        ScrollView {
            VStack(spacing: 16) {
                if !model.env.isReady && !model.env.isBuiltIn { warning }

                group {
                    row(loc.t("settings.appearance"), loc.t("settings.appearanceHint")) {
                        IconSegmented(items: AppearanceMode.allCases.map { ($0, $0.symbol, loc.t("appearance.\($0.rawValue)")) },
                                      selection: Binding(get: { appearance.mode }, set: { appearance.mode = $0 }), showLabels: true)
                    }
                    divider
                    row(loc.t("settings.language"), loc.t("settings.languageHint2")) {
                        Segmented(items: AppLanguage.allCases.map { ($0, $0 == .id ? "Indonesia" : "English") },
                                  selection: Binding(get: { loc.language }, set: { loc.language = $0 }), fontSize: 13, hPad: 14)
                    }
                }

                group { enginesBlock }

                group {
                    row(loc.t("settings.qualityTitle"), loc.t("settings.q.hint.\(model.quality)")) {
                        Segmented(items: ["economy", "balanced", "best"].map { ($0, loc.t("settings.q.\($0)")) },
                                  selection: $model.quality, fontSize: 13, hPad: 12)
                    }
                    divider
                    row(loc.t("settings.target"), model.targetLanguage == "Indonesian" ? loc.t("settings.targetHint") : loc.t("settings.targetHintOther")) {
                        Picker("", selection: $model.targetLanguage) {
                            ForEach(TargetLanguages.all, id: \.self) { Text(loc.t("langname.\($0)")).tag($0) }
                        }
                        .labelsHidden().frame(width: 190)
                    }
                    divider
                    row(loc.t("settings.style"), loc.t("settings.style.hint.\(model.styleMode.rawValue)")) {
                        Segmented(items: StyleMode.allCases.map { ($0, loc.t("settings.style.\($0.rawValue)")) },
                                  selection: $model.styleMode, fontSize: 13, hPad: 12)
                    }
                    divider
                    row(loc.t("settings.polish"), loc.t("settings.polishHint")) {
                        Toggle("", isOn: $model.polishNovels).labelsHidden().toggleStyle(.switch).tint(Theme.green)
                    }
                    divider
                    row(loc.t("settings.limit"), loc.t(model.keepModel ? "settings.limit.waitHint" : "settings.limit.switchHint")) {
                        Segmented(items: [(false, loc.t("settings.limit.switch")), (true, loc.t("settings.limit.wait"))],
                                  selection: $model.keepModel, fontSize: 13, hPad: 12)
                    }
                    divider
                    row(loc.t("settings.parallel"), loc.t("settings.parallelHint")) {
                        Segmented(items: AppModel.parallelChoices.map { ($0, "\($0)") },
                                  selection: $model.parallelRequests, fontSize: 13, hPad: 14)
                    }
                    Text(loc.t("settings.speedNote")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 10).background(Theme.sidePanel)
                }

                group {
                    row(loc.t("settings.libraryTitle"), model.env.booksDir.path) {
                        HStack {
                            Button(loc.t("settings.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([model.env.booksDir]) }.buttonStyle(GhostButtonStyle())
                            Button(loc.t("settings.change")) { chooseFolder(model.env.booksDir) { url in
                                UserDefaults.standard.set(url.path, forKey: "booksDir"); model.env.booksDir = url; model.library.reload(env: model.env, force: true)
                            } }.buttonStyle(GhostButtonStyle())
                        }
                    }
                    divider
                    if model.env.isBuiltIn {
                        row(loc.t("settings.backend"), model.engineSetup.state == .ready ? loc.t("settings.engineBuiltIn") : loc.t("settings.engineNotReady")) {
                            HStack {
                                Button(loc.t("settings.engineRepair")) { model.repairEngine() }.buttonStyle(GhostButtonStyle())
                                    .disabled(model.engineSetup.state == .working)
                                Button(loc.t("settings.engineUseFolder")) { model.chooseDeveloperFolder() }.buttonStyle(GhostButtonStyle())
                            }
                        }
                    } else {
                        row(loc.t("settings.backend"), model.env.root.path) {
                            HStack {
                                if BackendEnvironment.bundledEngine != nil {
                                    Button(loc.t("settings.engineUseBuiltIn")) { model.useBuiltInEngine() }.buttonStyle(GhostButtonStyle())
                                }
                                Button(loc.t("settings.change")) { model.chooseDeveloperFolder() }.buttonStyle(GhostButtonStyle())
                            }
                        }
                    }
                    divider
                    row(loc.t("settings.addToBooks"), loc.t("settings.addToBooksHint")) { Toggle("", isOn: $model.addToBooks).labelsHidden().toggleStyle(.switch).tint(Theme.green) }
                }

                kindleBlock

                group {
                    row(loc.t("settings.onlineMeta"), loc.t("settings.onlineMetaHint")) {
                        HStack {
                            if keyStored {
                                Pill(text: loc.t("settings.keySaved"), bg: Theme.okBg, fg: Theme.okText, size: 12)
                                Button(loc.t("settings.keyRemove")) { Secrets.googleBooksKey = ""; keyStored = false }.buttonStyle(GhostButtonStyle())
                            } else {
                                SecureField(loc.t("settings.keyPlaceholder"), text: $apiKey).textFieldStyle(.roundedBorder).frame(width: 180)
                                Button(loc.t("settings.keySave")) { Secrets.googleBooksKey = apiKey.trimmingCharacters(in: .whitespaces); apiKey = ""; keyStored = !Secrets.googleBooksKey.isEmpty }
                                    .buttonStyle(GhostButtonStyle()).disabled(apiKey.isEmpty)
                            }
                        }
                    }
                }

                group {
                    row(loc.t("settings.log"), loc.t("settings.logHint")) {
                        Toggle("", isOn: $model.keepLog).labelsHidden().toggleStyle(.switch).tint(Theme.green)
                    }
                    divider
                    row(loc.t("settings.logShare"), summaryCopied.map { loc.t($0 ? "settings.logCopied" : "settings.logCopyFailed") } ?? loc.t("settings.logShareHint")) {
                        HStack {
                            Button(loc.t("settings.logFolder")) { model.openLogFolder() }.buttonStyle(GhostButtonStyle())
                            Button(loc.t("settings.logCopy")) { Task { summaryCopied = await model.copyLogSummary() } }
                                .buttonStyle(GhostButtonStyle()).disabled(!model.env.isReady)
                            if summaryCopied == true {
                                Button(loc.t("settings.logReport")) { NSWorkspace.shared.open(AboutPanel.logReportURL) }.buttonStyle(GhostButtonStyle())
                            }
                        }
                    }
                    divider
                    row(loc.t("settings.logAbout"), loc.t("settings.logAboutHint")) {
                        Button(loc.t("settings.open")) { NSWorkspace.shared.open(AboutPanel.logPageURL) }.buttonStyle(GhostButtonStyle())
                    }
                }

                group {
                    row(loc.t("settings.keepAwake"), loc.t("settings.keepAwakeHint")) { Toggle("", isOn: $model.keepAwake).labelsHidden().toggleStyle(.switch).tint(Theme.green) }
                    divider
                    row(loc.t("settings.notifyVolume"), "") { Toggle("", isOn: $model.notifyVolume).labelsHidden().toggleStyle(.switch).tint(Theme.green) }
                    divider
                    row(loc.t("settings.notifyAttention"), loc.t("settings.notifyAttentionHint")) { Toggle("", isOn: $model.notifyAttention).labelsHidden().toggleStyle(.switch).tint(Theme.green) }
                }

                group {
                    row(Text(loc.t("app.title")).font(.system(size: 14, weight: .medium))
                        + Text(" " + loc.t("settings.versionNow", Updater.currentVersion, Updater.currentBuild)).font(.system(size: 14)).foregroundColor(Theme.muted),
                        updater.lastChecked.map { loc.t("settings.lastChecked", $0.formatted(date: .abbreviated, time: .shortened)) } ?? loc.t("settings.never")) {
                        Button(updater.state == .checking ? loc.t("settings.checking") : loc.t("settings.check")) { Task { await updater.check() } }
                            .buttonStyle(GhostButtonStyle()).disabled(updater.state == .checking || updater.state == .downloading)
                    }
                    divider
                    row(loc.t("settings.auto"), loc.t("settings.autoHint")) { Toggle("", isOn: $updater.autoUpdate).labelsHidden().toggleStyle(.switch).tint(Theme.green) }
                    updateBanner
                    divider
                    row(loc.t("settings.github"), loc.t("settings.githubHint")) {
                        Button(loc.t("settings.open")) { NSWorkspace.shared.open(AboutPanel.repositoryURL) }.buttonStyle(GhostButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
        }
        .frame(width: 700, height: height)
        .task { await updater.checkIfStale(Updater.settingsAge) }
        .background(Theme.window)
    }

    // MARK: - Pieces

    private var warning: some View {
        Label(loc.t("settings.backendMissing"), systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 13)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Theme.warnText).background(Theme.warnBg, in: RoundedRectangle(cornerRadius: 10))
    }

    private var divider: some View { Rectangle().fill(Theme.rowLine).frame(height: 1) }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        CardBox(radius: 12) { VStack(spacing: 0, content: content) }
    }

    private func row<Control: View>(_ title: String, _ hint: String, @ViewBuilder control: () -> Control) -> some View {
        row(Text(title).font(.system(size: 14, weight: .medium)), hint, control: control)
    }

    private func row<Control: View>(_ title: Text, _ hint: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                title
                if !hint.isEmpty { Text(hint).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2).truncationMode(.middle) }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder private var updateBanner: some View {
        switch updater.state {
        case .available(let release):
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc.t("settings.available", release.version)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accentDark)
                    Text(release.notes.isEmpty ? loc.t("settings.updateAfter") : String(release.notes.prefix(160))).font(.system(size: 12)).foregroundStyle(Theme.neutralText).lineLimit(2)
                }
                Spacer()
                if model.isBusy { Text(loc.t("settings.waitIdle")).font(.system(size: 12)).foregroundStyle(Theme.warnIcon) }
                else { Button(loc.t("settings.install")) { Task { await updater.install() } }.buttonStyle(PrimaryButtonStyle(radius: 8)) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12).background(Theme.readyBg)
        case .downloading:
            HStack { ProgressView().controlSize(.small); Text(loc.t("settings.installing")).font(.system(size: 13)) }.padding(16)
        case .upToDate:
            Label(loc.t("settings.upToDate", Updater.currentVersion), systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.green)
                .padding(.horizontal, 16).padding(.vertical, 10)
        case .failed(let message):
            Text(loc.t("settings.updateFailed", message)).font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.horizontal, 16).padding(.vertical, 10)
        default: EmptyView()
        }
    }

    // MARK: - Kindle

    private var kindleBlock: some View {
        @Bindable var model = model
        return group {
            row(loc.t("kindle.title"), loc.t("kindle.hint")) { EmptyView() }
            divider
            row(loc.t("kindle.to"), model.kindle.to.isEmpty || model.kindle.toLooksRight ? loc.t("kindle.toHint") : loc.t("kindle.error.kindle_address")) {
                TextField("nama@kindle.com", text: $model.kindle.to).textFieldStyle(.roundedBorder).frame(width: 260)
            }
            divider
            row(loc.t("kindle.from"), loc.t("kindle.fromHint")) {
                TextField("anda@gmail.com", text: $model.kindle.from).textFieldStyle(.roundedBorder).frame(width: 260)
            }
            divider
            row(loc.t("kindle.server"), model.kindle.server == .other ? loc.t("kindle.serverHint") : "\(model.kindle.host):\(model.kindle.port)") {
                Segmented(items: KindleServer.allCases.map { ($0, $0 == .other ? loc.t("kindle.server.other") : $0.label) },
                          selection: $model.kindle.server, fontSize: 12.5, hPad: 10)
            }
            if model.kindle.server == .other {
                divider
                row(loc.t("kindle.custom"), loc.t("kindle.customHint")) {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 6) {
                            TextField("smtp.example.com", text: $model.kindle.customHost).textFieldStyle(.roundedBorder).frame(width: 190)
                            TextField("587", text: $model.kindle.customPort).textFieldStyle(.roundedBorder).frame(width: 60)
                        }
                        TextField(loc.t("kindle.user"), text: $model.kindle.user).textFieldStyle(.roundedBorder).frame(width: 256)
                    }
                }
            }
            divider
            row(loc.t("kindle.password"), loc.t("kindle.passwordHint")) {
                HStack {
                    if model.kindlePasswordStored {
                        Pill(text: loc.t("settings.keySaved"), bg: Theme.okBg, fg: Theme.okText, size: 12)
                        Button(loc.t("settings.keyRemove")) { model.removeKindlePassword(); kindleTest = nil }.buttonStyle(GhostButtonStyle())
                    } else {
                        SecureField(loc.t("kindle.password"), text: $kindlePassword).textFieldStyle(.roundedBorder).frame(width: 190)
                        Button(loc.t("settings.keySave")) { model.saveKindlePassword(kindlePassword); kindlePassword = "" }
                            .buttonStyle(GhostButtonStyle()).disabled(kindlePassword.isEmpty)
                    }
                }
            }
            divider
            row(loc.t("kindle.test"), kindleTest?.text ?? loc.t("kindle.testHint")) {
                Button(kindleTesting ? loc.t("kindle.testing") : loc.t("kindle.test")) {
                    kindleTesting = true
                    Task { kindleTest = await model.testKindle(); kindleTesting = false }
                }
                .buttonStyle(PrimaryButtonStyle(radius: 8, vertical: 5, horizontal: 12, size: 12.5))
                .disabled(!model.kindleReady || kindleTesting || !model.env.isReady)
                .opacity(model.kindleReady ? 1 : 0.4)
            }
        }
    }

    // MARK: - Engines

    private static let badge: [String: (String, Color)] = [
        "claude": ("C", Color(hex: 0xD97757)), "codex": ("X", Theme.codexBadge), "agy": ("A", Theme.engineBlue),
        "opencode": ("O", Theme.engineGrey),
    ]

    private var enginesBlock: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.t("settings.engines")).font(.system(size: 14, weight: .medium))
                Text(loc.t("settings.enginesHint2")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            if model.enginesLoading && model.engines.isEmpty {
                HStack { ProgressView().controlSize(.small); Text(loc.t("settings.detecting")).font(.system(size: 13)) }.padding(16)
            }
            ForEach(Array(model.engines.enumerated()), id: \.element.id) { index, engine in
                divider
                engineRow(engine, backupNumber: model.engines.prefix(index).filter { $0.active }.count)
            }
            divider
            HStack {
                Text(loc.t("settings.dragHint")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Button(loc.t("settings.recheck")) { model.refreshEngines(force: true) }.buttonStyle(GhostButtonStyle()).disabled(model.enginesLoading)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).background(Theme.sidePanel)
        }
        .onAppear { model.loadModelChoices() }
    }

    private func engineRow(_ engine: EngineInfo, backupNumber: Int) -> some View {
        let (letter, color) = Self.badge[engine.name] ?? ("?", .gray)
        let waiting = !engine.active && engine.reason.lowercased().contains("quota") || engine.reason.lowercased().contains("limit")
        let position = model.engines.firstIndex { $0.name == engine.name } ?? 0
        return HStack(spacing: 12) {
            VStack(spacing: 4) {
                IconButton(symbol: "chevron.up", help: loc.t("input.up"), size: 22, enabled: position > 0,
                           fill: Theme.actionNonfiction) { model.moveEngine(engine.name, by: -1) }
                IconButton(symbol: "chevron.down", help: loc.t("input.down"), size: 22,
                           enabled: position < model.engines.count - 1,
                           fill: Theme.actionNonfiction) { model.moveEngine(engine.name, by: 1) }
            }
            Text(letter).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(color, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(engine.label).font(.system(size: 14, weight: .medium))
                Text(engineStatus(engine))
                    .font(.system(size: 12)).foregroundStyle(engine.active ? Theme.muted : Theme.warnIcon).lineLimit(2)
                    .fixedSize(horizontal: engine.active, vertical: true)      // a reason may wrap
                modelMenu(engine)
            }
            Spacer()
            if engine.role == "main" { Pill(text: loc.t("settings.main"), bg: Theme.fictionBg, fg: Theme.accentDark, size: 12) }
            else if engine.role == "backup" { Pill(text: loc.t("settings.backupN", backupNumber), bg: Theme.neutralBg, fg: Theme.neutralText, size: 12) }
            if engine.active { Pill(text: loc.t("settings.active"), bg: Theme.okBg, fg: Theme.okText, size: 12) }
            else if waiting { Pill(text: loc.t("settings.waiting"), bg: Theme.warnBg, fg: Theme.warnText, size: 12) }
            else { Pill(text: loc.t("settings.inactive"), bg: Theme.neutralBg, fg: Theme.neutralText, size: 12) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
        .draggable(engine.name)
        .dropDestination(for: String.self) { names, _ in
            if let first = names.first { model.moveEngine(first, before: engine.name) }
            return true
        }
    }

    private func engineStatus(_ engine: EngineInfo) -> String {
        if engine.lacksRecommendedModel { return loc.t("settings.noModel") }
        guard engine.active else { return engine.reason }
        return engine.role == "main" ? loc.t("settings.signedIn") : loc.t("settings.readyToReplace")
    }

    /// The engine's model: the recommended one is marked, any other of its models may be chosen.
    @ViewBuilder private func modelMenu(_ engine: EngineInfo) -> some View {
        if let offered = model.modelChoices[engine.name] {
            let chosen = model.engineModels[engine.name] ?? offered.recommended
            let own = chosen != offered.recommended
            let models = offered.choices.contains(chosen) ? offered.choices : [chosen] + offered.choices
            HStack(spacing: 8) {
                RowMenu(items: models.map { name in
                            (name, name == offered.recommended
                                ? loc.t("settings.model.recommended", EngineInfo.display(name)) : EngineInfo.display(name))
                        },
                        selection: Binding(get: { chosen }, set: { model.setModel(engine.name, $0) }),
                        fill: own ? Theme.actionFiction : Theme.actionPolish, width: 260, height: 24)
                    .disabled(model.enginesLoading)
                if own {
                    Text(loc.t("settings.model.untested")).font(.system(size: 11)).foregroundStyle(Theme.warnIcon).fixedSize()
                }
            }
            .fixedSize()
            .padding(.top, 4)
        } else if let name = engine.modelName {
            Text(name).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }

    private func chooseFolder(_ start: URL, pick: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = start
        if panel.runModal() == .OK, let url = panel.url { pick(url) }
    }
}
