import SwiftUI

enum Stage3: String, CaseIterable, Identifiable {
    case input, process, library
    var id: String { rawValue }
    var number: Int { self == .input ? 1 : (self == .process ? 2 : 3) }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    @Environment(Updater.self) private var updater
    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.openSettings) private var openSettings
    @State private var stage = Stage3.input
    @State private var openFolder: String?

    var body: some View {
        Group {
            switch stage {
            case .input: InputView(onStart: { stage = .process })
            case .process: ProcessView(goInput: { stage = .input }, openResult: { openFolder = $0; stage = .library })
            case .library: LibraryScreen(openFolder: $openFolder)
            }
        }
        .tint(Theme.accent)              // inside the body: a modifier on the scene would reset the window frame
        .frame(minWidth: 940, minHeight: 640)
        .background(Theme.window)
        .background(WindowConfigurator())
        // The system toolbar keeps the traffic lights centred; the stage bar and the theme switch live in it.
        .toolbar {
            ToolbarItem(placement: .principal) { stageSwitcher }.withoutGlass()
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 10) {
                    IconSegmented(items: AppearanceMode.allCases.map { ($0, $0.symbol, loc.t("appearance.\($0.rawValue)")) },
                                  selection: Binding(get: { appearance.mode }, set: { appearance.mode = $0 }))
                    Button { openSettings() } label: {
                        Image(systemName: "gearshape").font(.system(size: 14)).foregroundStyle(Theme.muted)
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(loc.t("nav.settings"))
                }
            }.withoutGlass()
        }
        .overlay { if model.needsEngineSetup { EngineSetupView() } }
        .toolbarBackground(Theme.bar, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .navigationTitle(loc.t("app.title"))
        .sheet(item: Binding(get: { model.reviewTarget.flatMap { model.book($0) } },
                             set: { if $0 == nil { model.reviewTarget = nil } })) { ReviewSheet(book: $0) }
        .onChange(of: model.reviewBooks.count) { old, new in
            // A book that needs review opens its sheet by itself.
            if new > old, model.reviewTarget == nil, let first = model.reviewBooks.last { model.reviewTarget = first.id }
        }
        .onChange(of: model.isBusy) { _, busy in
            if !busy { Task { await updater.installIfAllowed(queueIdle: model.waitingCount == 0) } }
        }
        .task {
            appearance.apply()
            if model.notifyVolume || model.notifyAttention { model.requestNotificationAccess() }
            if updater.autoUpdate { await updater.check(); await updater.installIfAllowed(queueIdle: !model.isBusy) }
        }
        .task { await updater.watch() }
    }

    private func count(_ s: Stage3) -> Int {
        switch s {
        case .input: return model.uploaded.count + model.readyList.count
        case .process: return model.queueList.count
        case .library: return model.library.books.filter { $0.isComplete }.count
        }
    }

    private var stageSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(Stage3.allCases) { s in
                let on = stage == s
                Button {
                    stage = s
                    if s != .library { openFolder = nil }
                } label: {
                    HStack(spacing: 8) {
                        Text("\(s.number)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onAccent)
                            .frame(width: 20, height: 20).background(on ? Theme.accent : Theme.stageIdle, in: Circle())
                        Text(loc.t("nav.\(s.rawValue)")).font(.system(size: 14, weight: on ? .semibold : .regular))
                        Text("\(count(s))").font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 18).padding(.vertical, 6)
                    .background(on ? Theme.selectedSeg : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .shadow(color: .black.opacity(on ? 0.18 : 0), radius: 1.5, y: 1)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(3).background(Theme.stageTrack, in: RoundedRectangle(cornerRadius: 11))
    }
}
