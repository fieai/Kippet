import AppKit
import SwiftUI

/// Shared colors, shapes and motion for the shelf so every surface moves and reads the same way.
enum ShelfTheme {
    static let accent = Color.teal
    static let warning = Color.orange
    static let cardRadius: CGFloat = 14
    static let chipRadius: CGFloat = 8

    static func tint(for kind: ClipKind) -> Color {
        switch kind {
        case .text: .teal
        case .link: .indigo
        case .image: .orange
        case .files: .blue
        }
    }

    /// Card surface that sits on the panel's vibrancy without looking like a flat white sheet.
    static var cardFill: Color { Color(nsColor: .controlBackgroundColor).opacity(0.78) }
    static var hairline: Color { Color.primary.opacity(0.08) }
    static var checkerBase: Color { Color(nsColor: .controlBackgroundColor) }
    static var checkerTile: Color { Color.primary.opacity(0.14) }

    static func syntaxTint(for kind: CodeSyntax.Kind) -> Color {
        switch kind {
        case .keyword: Color(nsColor: .systemPurple)
        case .string: Color(nsColor: .systemTeal)
        case .number: Color(nsColor: .systemBlue)
        case .comment: .secondary
        }
    }
}

enum ShelfMotion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let syncRotationPeriod: TimeInterval = 1.2

    /// Selection, hover and lift: quick with a hint of settle.
    static var lift: Animation { reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.78) }
    /// Moving highlights such as the pinboard indicator.
    static var glide: Animation { reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.36, dampingFraction: 0.86) }
    /// Swapping the main content area (cards, preview, stack).
    static var swap: Animation { reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.34, dampingFraction: 0.9) }
    /// Insertions and removals in lists.
    static var list: Animation { reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.38, dampingFraction: 0.84) }

    static func entrance(_ index: Int) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12)
            : .spring(response: 0.42, dampingFraction: 0.8).delay(0.03 + Double(index) * 0.028)
    }
}

/// Cards near the front slide up in sequence when the shelf opens; later ones simply appear.
struct ShelfCardEntrance: ViewModifier {
    let index: Int
    let animates: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        let visible = shown || !animates
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 22)
            .scaleEffect(visible ? 1 : 0.96, anchor: .bottom)
            .onAppear {
                guard animates, !shown else { return }
                withAnimation(ShelfMotion.entrance(index)) { shown = true }
            }
    }
}

/// Toolbar glyph buttons: soft hover plate, slight press squeeze.
struct ShelfGlyphButtonStyle: ButtonStyle {
    var isActive = false
    var size: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        GlyphBody(configuration: configuration, isActive: isActive, size: size)
    }

    private struct GlyphBody: View {
        let configuration: ButtonStyleConfiguration
        let isActive: Bool
        let size: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? ShelfTheme.accent : (hovering ? Color.primary : Color.secondary))
                .frame(width: size, height: size)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? ShelfTheme.accent.opacity(0.16)
                              : Color.primary.opacity(hovering ? 0.08 : 0))
                }
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(ShelfMotion.lift, value: hovering)
                .animation(ShelfMotion.lift, value: configuration.isPressed)
                .animation(ShelfMotion.lift, value: isActive)
        }
    }
}

/// Short-lived status text in the footer slides up and fades instead of popping.
struct ShelfToastTransition {
    static var transition: AnyTransition {
        .asymmetric(
            insertion: .offset(y: 8).combined(with: .opacity),
            removal: .opacity
        )
    }
}
