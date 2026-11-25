import SwiftUI

@main
struct BookTranslatorApp: App {
    @State private var model = AppModel(deferStartup: true)
    @State private var updater = Updater()
    @State private var loc = Loc.shared
    @State private var appearance = AppearanceStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model).environment(updater).environment(loc).environment(appearance)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .appInfo) { AboutMenuButton().environment(loc) }
        }

        Window("NNAI Translator", id: "about") {
            AboutView().environment(loc).environment(appearance)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(model).environment(updater).environment(loc).environment(appearance)
        }

        MenuBarExtra {
            MenuBarContent().environment(model).environment(loc)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.isBusy ? "book.fill" : "book")
                if let book = model.running, book.stage == .translating { Text("\(book.pct)%") }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu-bar popover of the design: what runs, what is next, pause and open.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let book = model.running {
                HStack(spacing: 12) {
                    CoverView(title: book.title, image: model.queueCovers[book.id], width: 44, height: 62, radius: 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(book.stage == .preparing ? loc.t("process.preparing") : loc.t("menu.volumeOf", max(book.volume, 1), book.volumes))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                        Text(book.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                        Text(model.etaDescription(loc)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                ProgressBar(value: Double(book.pct) / 100, tint: Theme.accent)
            } else {
                Text(model.paused ? loc.t("process.paused") : loc.t("menu.idle")).font(.system(size: 13, weight: .medium))
            }
            let rest = model.queueList.filter { $0.id != model.runningID }
            if !rest.isEmpty {
                Divider()
                VStack(spacing: 6) {
                    ForEach(Array(rest.prefix(3).enumerated()), id: \.element.id) { index, book in
                        HStack {
                            Text(loc.t(index == 0 ? "menu.next" : "menu.then", book.title)).lineLimit(1)
                            Spacer()
                            Text(loc.volumes(book.volumes)).foregroundStyle(Theme.muted)
                        }.font(.system(size: 13))
                    }
                }
            }
            HStack(spacing: 8) {
                if model.isBusy || model.paused {
                    Button(model.paused ? loc.t("process.resume") : loc.t("process.pause")) { model.paused ? model.resume() : model.pause() }
                        .buttonStyle(GhostButtonStyle()).frame(maxWidth: .infinity)
                }
                Button(loc.t("menu.openApp")) {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                }.buttonStyle(PrimaryButtonStyle(radius: 8)).frame(maxWidth: .infinity)
            }
            Button(loc.t("menu.quit")) { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .padding(14).frame(width: 320)
    }
}
