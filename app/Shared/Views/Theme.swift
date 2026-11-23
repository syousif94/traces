import SwiftUI

/// Design tokens from the spec: Nord (dark) and Day (light). No pure black or red as primary colours.
enum Theme {
    static func dyn(_ dark: UInt32, _ light: UInt32) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #else
        Color(uiColor: UIColor { t in t.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #endif
    }

    static let canvas = dyn(0x2E3440, 0xE5E9F0)
    static let surface = dyn(0x3B4252, 0xFFFFFF)
    static let surfaceRaised = dyn(0x434C5E, 0xECEFF4)
    static let text = dyn(0xECEFF4, 0x2E3440)
    static let muted = dyn(0xAEB6C4, 0x4C566A)
    /// The home screen's accent: solder-mask green. In a project, use the mode's `Palette`.
    static let accent = Color(hex: 0x2FA866)
    static let accentText = accent
    static let onAccent = Color.white
    static let success = Color(hex: 0xA3BE8C)
    static let warning = Color(hex: 0xEBCB8B)
    static let danger = Color(hex: 0xBF616A)
    static let userBubble = dyn(0x5E81AC, 0x5E81AC)
    static let separator = dyn(0x4C566A, 0xD8DEE9)
    static let addedLine = dyn(0x3F4D45, 0xE6EFE0)
    static let removedLine = dyn(0x4C3F47, 0xF6E3E2)

    // Board colours (same in both themes).
    static let board = Color(hex: 0x2B3A33)
    static let boardEdge = Color(hex: 0x8FBCBB)
    static let copperTop = Color(hex: 0xD08770)
    static let copperBottom = Color(hex: 0x81A1C1)
    static let pad = Color(hex: 0xE5C07B)
    static let silk = Color(hex: 0xECEFF4)
    static let courtyard = Color(hex: 0x88C0D0)
    static let hole = Color(hex: 0x1F252E)

    // Schematic.
    static let schBackground = dyn(0x2E3440, 0xF4F6F9)
    static let schLine = dyn(0x88C0D0, 0x3B6E8F)
    static let schBody = dyn(0xD8DEE9, 0x2E3440)
    static let schLabel = dyn(0xEBCB8B, 0x8A6A1D)

    static let radiusToolbar: CGFloat = 22
    static let radiusButton: CGFloat = 14
    static let radiusPanel: CGFloat = 24
    /// The studio's floating glass panels (Nurby's squircle).
    static let panelRadius: CGFloat = 40
    static func selectedRow(_ scheme: ColorScheme) -> Color { scheme == .dark ? .white.opacity(0.09) : .black.opacity(0.055) }

    static let mono = Font.system(.body, design: .monospaced)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

#if os(macOS)
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// Floating surfaces over the full-bleed canvas: tinted glass with squircle corners.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = Theme.radiusPanel
    func body(content: Content) -> some View {
        content
            .background(Theme.surface.opacity(0.84), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.separator.opacity(0.5), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }
}

extension View {
    func glassPanel(radius: CGFloat = Theme.radiusPanel) -> some View { modifier(GlassPanel(radius: radius)) }
}

/// Pill button styles used across platforms.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, success, secondary, plain }
    var kind: Kind = .secondary
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        let (bg, fg): (Color, Color) = switch kind {
        case .primary: (Theme.accent, Theme.onAccent)
        case .success: (Theme.success, Color(hex: 0x2E3440))
        case .secondary: (Theme.surfaceRaised, Theme.text)
        case .plain: (.clear, Theme.text)
        }
        configuration.label
            .font(.system(size: compact ? 13 : 15, weight: .semibold))
            .padding(.horizontal, compact ? 12 : 16)
            .frame(minHeight: compact ? 34 : 44)
            .background(bg.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous))
            .foregroundStyle(fg)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous))
    }
}

#if os(macOS)
extension NSColor {
    static func dynamic(_ dark: UInt32, _ light: UInt32) -> NSColor {
        NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light) }
    }
}
#else
extension UIColor {
    static func dynamic(_ dark: UInt32, _ light: UInt32) -> UIColor {
        UIColor { t in t.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }
}
#endif

/// A round header button: one symbol on a faint disc, 34 pt.
struct HeaderIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .frame(width: 34, height: 34)
            .background(.primary.opacity(0.07), in: .circle)
            .contentShape(.circle)
    }
}

/// Each view of a project has its own look: Schematic is sepia paper with red ink, PCB is dark with
/// green, 3D is dark with orange, Code is dark with teal. The studio sets the palette, the tint and
/// the colour scheme from the view mode; views read accents from `@Environment(\.palette)`.
struct Palette: Equatable {
    var accent: Color
    /// The full-bleed background behind the canvas.
    var canvas: Color
    /// Grid dots and faint marks on the canvas.
    var grid: Color
    var scheme: ColorScheme

    static let schematic = Palette(accent: Color(hex: 0xB23A2C), canvas: Color(hex: 0xF2E8D5),
                                   grid: Color(hex: 0x8C6E4E).opacity(0.35), scheme: .light)
    static let pcb = Palette(accent: Color(hex: 0x3DCB7A), canvas: Color(hex: 0x0E1511),
                             grid: Color(hex: 0x6FA584).opacity(0.22), scheme: .dark)
    static let threeD = Palette(accent: Color(hex: 0xF28C28), canvas: Color(hex: 0x16120F),
                                grid: Color(hex: 0xB08A66).opacity(0.22), scheme: .dark)
    static let code = Palette(accent: Color(hex: 0x4FC1C9), canvas: Color(hex: 0x12161C),
                              grid: Color(hex: 0x7A8899).opacity(0.22), scheme: .dark)
    static let home = Palette(accent: Theme.accent, canvas: Theme.canvas, grid: Theme.muted.opacity(0.22), scheme: .dark)

    static func `for`(_ mode: ViewMode) -> Palette {
        switch mode { case .schematic: schematic; case .pcb: pcb; case .threeD: threeD; case .code: code }
    }

    // Schematic ink on the sepia paper.
    static let schLine = Color(hex: 0x6B4A2F)
    static let schBody = Color(hex: 0x3B2A1C)
    static let schLabel = Color(hex: 0xB23A2C)
    static let schMuted = Color(hex: 0x7D6650)
}

extension EnvironmentValues {
    @Entry var palette: Palette = .home
}
