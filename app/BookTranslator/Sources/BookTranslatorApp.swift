import SwiftUI

@main
struct BookTranslatorApp: App {
    @State private var model = AppModel()
    @State private var updater = Updater()
    @State private var loc = Loc.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(updater)
                .environment(loc)
        }
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
                .environment(loc)
        } label: {
            Image(systemName: model.isBusy ? "book.fill" : "book")
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let book = model.running {
            Text(book.title).font(.headline)
            Text(book.stage == .preparing ? loc.t("process.preparing") :
                    "\(loc.t("process.volumeOf", max(book.volume, 1), book.volumes)) · \(book.pct)%")
            Button(loc.t("process.pause")) { model.pause() }
        } else if model.paused {
            Text(loc.t("process.paused"))
            Button(loc.t("process.resume")) { model.resume() }
        } else {
            Text(loc.t("menu.idle"))
        }
        Divider()
        Button(loc.t("menu.open")) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        Button(loc.t("menu.quit")) { NSApp.terminate(nil) }
    }
}
