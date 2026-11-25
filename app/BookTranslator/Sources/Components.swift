import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The colours of the design canvas.
enum Theme {
    static let window = Color(hex: 0xF5F5F7)
    static let bar = Color(hex: 0xEDEDF0)
    static let barLine = Color(hex: 0xDCDCE1)
    static let card = Color.white
    static let line = Color(hex: 0xE3E3E8)
    static let rowLine = Color(hex: 0xEFEFF3)
    static let ink = Color(hex: 0x1D1D1F)
    static let muted = Color(hex: 0x55555A)
    static let faint = Color(hex: 0x6E6E73)
    static let accent = Color(hex: 0x0066D6)
    static let accentDark = Color(hex: 0x0A4FA8)
    static let green = Color(hex: 0x1E7B34)
    static let okBg = Color(hex: 0xE7F3EA)
    static let okText = Color(hex: 0x1E5B2B)
    static let warnBg = Color(hex: 0xFFF1D6)
    static let warnText = Color(hex: 0x7A4D00)
    static let warnIcon = Color(hex: 0x8A5A00)
    static let amber = Color(hex: 0xB7791F)
    static let readyBg = Color(hex: 0xF2F7FF)
    static let readyLine = Color(hex: 0xCFE0F8)
    static let dashed = Color(hex: 0xB8C4D8)
    static let segTrack = Color(hex: 0xE4E4E9)
    static let buttonLine = Color(hex: 0xC9C9D0)
    static let fictionBg = Color(hex: 0xEAF1FD)
    static let neutralBg = Color(hex: 0xEEF0F3)
    static let neutralText = Color(hex: 0x3A3A3C)
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
                        .padding(.horizontal, hPad).padding(.vertical, vPad)
                        .background(on ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 6))
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
            .background(configuration.isPressed ? Color.black.opacity(0.06) : (bordered ? Color.white : .clear), in: RoundedRectangle(cornerRadius: 8))
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
                    Text(title).font(.custom("Georgia", size: 10.5)).foregroundStyle(.white).lineLimit(4)
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
