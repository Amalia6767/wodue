import SwiftUI
import AppKit

// The interface uses two hues only: purple ink and coral. Hierarchy comes from
// lightness and opacity within those two families, never from extra colors.
enum Palette {
    static let paper = Color(hex: 0xF8F5F0)
    static let ambient = Color(hex: 0xF3EFEF)
    static let sidebar = Color(hex: 0xF0ECEF)
    static let card = Color(hex: 0xFFFDF9)
    static let ink = Color(hex: 0x332D3D)
    static let secondary = Color(hex: 0x625A69)
    static let line = Color(hex: 0xE4DEE5)
    static let accent = Color(hex: 0x332D3D)
    static let selection = Color(hex: 0xECE6F0)
    static let coral = Color(hex: 0xCA5140)
    static let coralText = Color(hex: 0x9E3B2C)
    static let green = Color(hex: 0x4A4252)
    static let error = Color(hex: 0xA8402F)
    static let errorTint = Color(hex: 0xF8E6E1)
    static let warning = Color(hex: 0x5A4F63)
    static let warningTint = Color(hex: 0xEEE9F0)
    static let taskColor: UInt32 = 0x82718E
    static let restColor: UInt32 = 0xB9B1BF
    static func ink(_ opacity: Double) -> Color { ink.opacity(opacity) }
    static func coral(_ opacity: Double) -> Color { coral.opacity(opacity) }
}

private enum BrandImages {
    static let wordmark = image("WoDueWordmarkTrim")
    static let symbol = image("WoDueSymbol")
    private static func image(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }
}

struct BrandWordmark: View {
    var body: some View {
        Group {
            if let image = BrandImages.wordmark {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Text("我Due！").font(.system(size: 25, weight: .bold, design: .rounded))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("我Due！")
        .accessibilityAddTraits(.isHeader)
    }
}

/// The coral speaking-u mark, used where the app talks to the person.
struct BrandSymbol: View {
    var body: some View {
        Group {
            if let image = BrandImages.symbol {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "mouth").foregroundColor(Palette.coral)
            }
        }.accessibilityHidden(true)
    }
}

struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 15).padding(.vertical, 10)
            .foregroundColor(enabled ? .white : Palette.secondary)
            .background(enabled ? Palette.accent : Palette.line, in: RoundedRectangle(cornerRadius: 9))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// Quiet translucent button used next to a primary action.
struct GlassButtonStyle: ButtonStyle {
    var height: CGFloat = 36
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).frame(height: height)
            .foregroundColor(Palette.ink)
            .background(Color.white.opacity(configuration.isPressed ? 0.35 : 0.55), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.ink(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Soft coral and violet light behind the frosted surfaces, so the glass has
/// something to blur.
struct AmbientBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Palette.ambient
                glow(Palette.coral(0.20), radius: 360).position(x: proxy.size.width * 0.62, y: 60)
                glow(Color(hex: 0x6E5C80).opacity(0.18), radius: 400).position(x: 120, y: proxy.size.height * 0.9)
                glow(Palette.coral(0.12), radius: 320).position(x: proxy.size.width, y: proxy.size.height)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
    private func glow(_ color: Color, radius: CGFloat) -> some View {
        Circle().fill(RadialGradient(colors: [color, color.opacity(0)], center: .center, startRadius: 0, endRadius: radius))
            .frame(width: radius * 2, height: radius * 2)
    }
}

extension View {
    /// Hides scroll bars even when macOS is set to always show them, and fades
    /// the top and bottom edges so it stays clear that more content continues.
    func quietScroll() -> some View {
        scrollIndicators(.never).mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 30)
            }
        }
    }

    /// Frosted glass card: system material, a warm white wash, a bright hairline
    /// edge and a very soft shadow.
    func glassCard(radius: CGFloat = 18) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: radius).fill(Color(hex: 0xFFFDFB).opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.white.opacity(0.75)))
                .shadow(color: Palette.ink(0.06), radius: 15, y: 8)
        }
    }
}
