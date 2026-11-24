import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case input, process, library, settings
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .input: return "tray.and.arrow.down"
        case .process: return "gearshape.2"
        case .library: return "books.vertical"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    @Environment(Updater.self) private var updater
    @State private var screen: Screen? = .input

    var body: some View {
        NavigationSplitView {
            List(selection: $screen) {
                Section {
                    row(.input)
                    row(.process).badge(model.readyList.count)
                    row(.library).badge(model.library.books.filter { $0.isComplete }.count)
                }
                Section { row(.settings) }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            switch screen ?? .input {
            case .input: InputView()
            case .process: ProcessView { screen = .input }
            case .library: LibraryScreen()
            case .settings: SettingsView()
            }
        }
        .navigationTitle(loc.t("app.title"))
        .frame(minWidth: 980, minHeight: 640)
        .sheet(item: Binding(get: { model.reviewTarget.flatMap { model.book($0) } },
                             set: { if $0 == nil { model.reviewTarget = nil } })) { ReviewSheet(book: $0) }
        .onChange(of: model.reviewBooks.count) { old, new in
            // A book that needs review opens its sheet by itself when the app is in front.
            if new > old, model.reviewTarget == nil, let first = model.reviewBooks.last { model.reviewTarget = first.id }
        }
        .onChange(of: model.isBusy) { _, busy in
            if !busy { Task { await updater.installIfAllowed(queueIdle: model.waitingCount == 0) } }
        }
        .task {
            if model.notificationsOn { model.requestNotificationAccess() }
            if updater.autoUpdate { await updater.check(); await updater.installIfAllowed(queueIdle: !model.isBusy) }
        }
    }

    private func row(_ target: Screen) -> some View {
        Label(loc.t("nav.\(target.rawValue)"), systemImage: target.icon).tag(target)
    }
}
