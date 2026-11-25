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
    @Environment(\.openSettings) private var openSettings
    @State private var stage = Stage3.input
    @State private var openFolder: String?

    var body: some View {
        Group {
            switch stage {
            case .input: InputView(onStart: { stage = .process })
            case .process: ProcessView { stage = .input }
            case .library: LibraryScreen(openFolder: $openFolder)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .background(Theme.window)
        .toolbar {
            ToolbarItem(placement: .principal) { stageSwitcher }
            ToolbarItem(placement: .primaryAction) {
                Button { openSettings() } label: { Image(systemName: "gearshape") }.help(loc.t("nav.settings"))
            }
        }
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
            if model.notifyVolume || model.notifyAttention { model.requestNotificationAccess() }
            if updater.autoUpdate { await updater.check(); await updater.installIfAllowed(queueIdle: !model.isBusy) }
        }
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
                        Text("\(s.number)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(on ? Theme.accent : Color(hex: 0xB8B8C0), in: Circle())
                        Text(loc.t("nav.\(s.rawValue)")).font(.system(size: 14, weight: on ? .semibold : .regular))
                        Text("\(count(s))").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 18).padding(.vertical, 6)
                    .background(on ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .shadow(color: .black.opacity(on ? 0.2 : 0), radius: 1.5, y: 1)
                }.buttonStyle(.plain)
            }
        }
        .padding(3).background(Color(hex: 0xDEDEE3), in: RoundedRectangle(cornerRadius: 11))
    }
}
