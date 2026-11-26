import SwiftUI
import AppKit
import Observation

/// Light, dark, or follow the Mac.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@Observable
final class AppearanceStore {
    static let shared = AppearanceStore()

    var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "appearanceMode")
            apply()
        }
    }

    init() {
        mode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? "") ?? .system
    }

    /// Sets the appearance of every window, sheet and the menu-bar popover at once.
    func apply() { NSApp?.appearance = mode.nsAppearance }
}

/// Icon-only (or icon and label) segmented control.
struct IconSegmented<T: Hashable>: View {
    var items: [(value: T, symbol: String, label: String)]
    @Binding var selection: T
    var showLabels = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                let on = item.value == selection
                Button { selection = item.value } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol).font(.system(size: 12, weight: .semibold))
                        if showLabels { Text(item.label).font(.system(size: 13)).lineLimit(1).fixedSize() }
                    }
                    .foregroundStyle(on ? Theme.ink : Theme.muted)
                    .padding(.horizontal, showLabels ? 12 : 9).padding(.vertical, 5)
                    .background(on ? Theme.selectedSeg : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(on ? 0.18 : 0), radius: 1, y: 1)
                }
                .buttonStyle(.plain).help(item.label)
            }
        }
        .padding(2).background(Theme.segTrack, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Small window helper: a theme-aware window background, and (only when BT_DUMP_WINDOW is set) a dump of the
/// real window geometry so the layout can be checked on the running app.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfigView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ConfigView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.backgroundColor = NSColor(name: nil) { a in
                a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0x1F1B18) : NSColor(hex: 0xF9F4EE)
            }
            if let path = ProcessInfo.processInfo.environment["BT_DUMP_WINDOW"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak window] in
                    guard let window else { return }
                    var info: [String: Any] = ["windowHeight": window.frame.height, "windowWidth": window.frame.width,
                                               "contentLayoutTop": window.frame.height - window.contentLayoutRect.maxY,
                                               "hasToolbar": window.toolbar != nil,
                                               "styleMask": window.styleMask.rawValue]
                    for (name, kind) in [("close", NSWindow.ButtonType.closeButton), ("mini", .miniaturizeButton), ("zoom", .zoomButton)] {
                        if let b = window.standardWindowButton(kind) {
                            let r = b.convert(b.bounds, to: nil)
                            info[name] = ["x": r.minX, "centerFromTop": window.frame.height - r.midY, "size": r.width, "hidden": b.isHidden]
                        }
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: URL(fileURLWithPath: path))
                    }
                    // The whole window as drawn by the running app, title bar and toolbar included.
                    if let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                        frame.cacheDisplay(in: frame.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".png"))
                    }
                }
            }
        }
    }
}

extension ToolbarContent {
    /// macOS 26 wraps toolbar items in a glass capsule; the stage bar and theme switch draw their own.
    @ToolbarContentBuilder func withoutGlass() -> some ToolbarContent {
        if #available(macOS 26.0, *) { self.sharedBackgroundVisibility(.hidden) } else { self }
    }
}
