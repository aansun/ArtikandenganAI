import SwiftUI

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }

    /// A colour that follows the window's appearance (light or dark).
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

/// The colours of the design canvas, each with a light and a dark value.
enum Theme {
    static let window = Color(light: 0xF5F5F7, dark: 0x1C1C1E)
    static let bar = Color(light: 0xEDEDF0, dark: 0x262628)
    static let barLine = Color(light: 0xDCDCE1, dark: 0x3A3A3E)
    static let card = Color(light: 0xFFFFFF, dark: 0x2A2A2D)
    static let line = Color(light: 0xE3E3E8, dark: 0x3A3A3E)
    static let rowLine = Color(light: 0xEFEFF3, dark: 0x343438)
    static let ink = Color(light: 0x1D1D1F, dark: 0xF5F5F7)
    static let muted = Color(light: 0x55555A, dark: 0xA1A1A6)
    static let faint = Color(light: 0x6E6E73, dark: 0x8E8E93)
    static let accent = Color(light: 0x0066D6, dark: 0x3D8BFF)
    static let accentDark = Color(light: 0x0A4FA8, dark: 0x8DBBFF)
    static let green = Color(light: 0x1E7B34, dark: 0x3DBE5A)
    static let okBg = Color(light: 0xE7F3EA, dark: 0x1F3A28)
    static let okText = Color(light: 0x1E5B2B, dark: 0x7FD497)
    static let warnBg = Color(light: 0xFFF1D6, dark: 0x3D3217)
    static let warnText = Color(light: 0x7A4D00, dark: 0xF2C46D)
    static let warnIcon = Color(light: 0x8A5A00, dark: 0xE0B25A)
    static let amber = Color(light: 0xB7791F, dark: 0xE0A030)
    static let readyBg = Color(light: 0xF2F7FF, dark: 0x1B2638)
    static let readyLine = Color(light: 0xCFE0F8, dark: 0x2E4466)
    static let dashed = Color(light: 0xB8C4D8, dark: 0x4D5C78)
    static let segTrack = Color(light: 0xE4E4E9, dark: 0x3A3A3E)
    static let selectedSeg = Color(light: 0xFFFFFF, dark: 0x636366)
    static let buttonLine = Color(light: 0xC9C9D0, dark: 0x5A5A5E)
    static let fictionBg = Color(light: 0xEAF1FD, dark: 0x1F3452)
    static let neutralBg = Color(light: 0xEEF0F3, dark: 0x3A3A3E)
    static let neutralText = Color(light: 0x3A3A3C, dark: 0xD1D1D6)
    static let divider = Color(light: 0xE5E5EA, dark: 0x3A3A3E)
    static let subtleDivider = Color(light: 0xF2F2F5, dark: 0x343438)
    static let fieldBorder = Color(light: 0xD2D2D7, dark: 0x55555A)
    static let rowBorder = Color(light: 0xECECF0, dark: 0x3A3A3E)
    static let readyRowBorder = Color(light: 0xD5E3F8, dark: 0x34507A)
    static let dropFill = Color(light: 0xF9FBFE, dark: 0x1F2836)
    static let selectedFill = Color(light: 0xF4F8FE, dark: 0x1F2F47)
    static let unselectedBorder = Color(light: 0xE1E1E6, dark: 0x48484C)
    static let grip = Color(light: 0xB0B0B8, dark: 0x6E6E73)
    static let dotIdle = Color(light: 0xD8D8DE, dark: 0x48484C)
    static let trackBar = Color(light: 0xE8E8ED, dark: 0x3A3A3E)
    static let numCircle = Color(light: 0xE4E4E9, dark: 0x48484C)
    static let stageTrack = Color(light: 0xDEDEE3, dark: 0x38383C)
    static let stageIdle = Color(light: 0xB8B8C0, dark: 0x6E6E73)
    static let sidePanel = Color(light: 0xFAFAFB, dark: 0x232326)
    static let queueText = Color(light: 0x4A4A50, dark: 0xD1D1D6)
    static let codexBadge = Color(light: 0x1D1D1F, dark: 0x5A5A5E)
}

struct Pill: View {
    var text: String
    var bg: Color
    var fg: Color
    var size: CGFloat = 11
    var body: some View {
        Text(text).font(.system(size: size, weight: .medium)).foregroundStyle(fg)
            .padding(.horizontal, 9).padding(.vertical, 2.5).background(bg, in: Capsule())
    }
}

extension BookKind {
    var pillBg: Color { self == .fiction ? Theme.fictionBg : Theme.neutralBg }
    var pillFg: Color { self == .fiction ? Theme.accentDark : Theme.neutralText }
}

/// The macOS-style segmented control of the design (grey track, white selected segment).
struct Segmented<T: Hashable>: View {
    var items: [(T, String)]
    @Binding var selection: T
    var fontSize: CGFloat = 12
    var hPad: CGFloat = 11
    var vPad: CGFloat = 4

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                let (value, label) = items[i]
                let on = value == selection
                Button { selection = value } label: {
                    Text(label).font(.system(size: fontSize)).foregroundStyle(on ? Theme.ink : Theme.muted)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, hPad).padding(.vertical, vPad)
                        .background(on ? Theme.selectedSeg : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(on ? 0.2 : 0), radius: 1, y: 1)
                }.buttonStyle(.plain)
            }
        }
        .padding(2).background(Theme.segTrack, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var radius: CGFloat = 9
    var fill: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(configuration.isPressed ? fill.opacity(0.8) : fill, in: RoundedRectangle(cornerRadius: radius))
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

struct GhostButtonStyle: ButtonStyle {
    var tint: Color = Theme.ink
    var bordered = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12.5)).foregroundStyle(tint)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(configuration.isPressed ? Color.black.opacity(0.06) : (bordered ? Theme.card : .clear), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(bordered ? Theme.buttonLine : .clear))
    }
}

struct IconButton: View {
    var symbol: String
    var help: String
    var size: CGFloat = 26
    var enabled = true
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.neutralText)
                .frame(width: size, height: size).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.3).help(help)
    }
}

enum Covers {
    private static let palette: [(UInt32, UInt32)] = [
        (0x1F4E5A, 0x0D2730), (0x4A5F8A, 0x252F4A), (0x5B4A78, 0x2A2140), (0x6B7A45, 0x35401F), (0x8A2F3A, 0x431219),
        (0xB8742A, 0x5C3410), (0x4D5560, 0x262B32), (0x2F6A62, 0x123430), (0x6A3A2A, 0x2E1710), (0x3A4A3A, 0x161D16),
        (0xB86A86, 0x5A2A40), (0x2A6A8A, 0x10303F), (0x8A7A5A, 0x3F3622), (0x5A7A4A, 0x27381F),
    ]

    /// A stable pick from the title (String.hashValue changes at every launch).
    static func gradient(for title: String) -> LinearGradient {
        var h: UInt64 = 5381
        for byte in title.utf8 { h = (h &* 33) &+ UInt64(byte) }
        let pair = palette[Int(h % UInt64(palette.count))]
        return LinearGradient(colors: [Color(hex: pair.0), Color(hex: pair.1)], startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1))
    }
}

/// A cover: the book's own image when it has one, else a gradient (with the title if asked).
struct CoverView: View {
    var title: String
    var image: NSImage? = nil
    var width: CGFloat
    var height: CGFloat
    var showTitle = false
    var radius: CGFloat = 4

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                Image(nsImage: image).resizable().scaledToFill().frame(width: width, height: height).clipped()
            } else {
                Rectangle().fill(Covers.gradient(for: title))
                if showTitle {
                    Text(title).font(.custom("Georgia", size: max(10.5, width * 0.095))).foregroundStyle(.white).lineLimit(5)
                        .padding(7).multilineTextAlignment(.leading)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .shadow(color: .black.opacity(0.22), radius: width > 80 ? 6 : 2.5, y: width > 80 ? 3 : 1.5)
    }
}

struct CardBox<Content: View>: View {
    var fill: Color = Theme.card
    var border: Color = Theme.line
    var radius: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content.background(fill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(border))
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}


/// A cover looked up from several sources, cached, with a spinner while it loads and a clear fallback.
struct RemoteImage: View {
    var urls: [URL]
    var title: String
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat = 4
    @State private var image: NSImage?
    @State private var failed = false

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Covers.gradient(for: title).opacity(0.55))
                if urls.isEmpty || failed {
                    Image(systemName: "photo").font(.system(size: min(width, height) * 0.3)).foregroundStyle(.white.opacity(0.8))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(width: width, height: height).clipped()
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        .task(id: urls) { await load() }
    }

    private func load() async {
        image = nil; failed = false
        guard !urls.isEmpty else { return }
        let key = urls.map(\.absoluteString).joined(separator: "|") as NSString
        if let cached = Self.cache.object(forKey: key) { image = cached; return }
        if let data = await CoverFetcher.fetch(urls), let loaded = NSImage(data: data) {
            Self.cache.setObject(loaded, forKey: key)
            image = loaded
        } else {
            failed = true
        }
    }
}
