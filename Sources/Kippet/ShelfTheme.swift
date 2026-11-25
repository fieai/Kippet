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

/// One motion language for the whole shelf. See `ShelfMotionSpec` for the roles and numbers.
enum ShelfMotion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let syncRotationPeriod: TimeInterval = 1.2

    private static func animation(_ role: ShelfMotionSpec.Role) -> Animation {
        if reduceMotion { return .easeOut(duration: ShelfMotionSpec.reducedFade) }
        let spring = ShelfMotionSpec.spring(role)
        return .spring(response: spring.response, dampingFraction: spring.damping)
    }

    /// Button press and release.
    static var press: Animation { animation(.press) }
    /// Selection and focus, which people repeat quickly with the arrow keys.
    static var select: Animation { animation(.select) }
    /// Hover, toggles and small badges.
    static var lift: Animation { animation(.lift) }
    /// Moving highlights and scroll positions such as the pinboard indicator.
    static var glide: Animation { animation(.glide) }
    /// Swapping the main content area (cards, preview, stack) and popovers.
    static var swap: Animation { animation(.swap) }
    /// Insertions and removals in lists.
    static var list: Animation { animation(.list) }
    /// Content that arrives by itself, such as a decoded thumbnail.
    static var fade: Animation {
        .easeOut(duration: reduceMotion ? ShelfMotionSpec.reducedFade : ShelfMotionSpec.fade)
    }

    static func entrance(_ index: Int, cascade: Bool = true) -> Animation {
        if reduceMotion { return .easeOut(duration: ShelfMotionSpec.reducedFade) }
        let spring = cascade ? ShelfMotionSpec.entranceSpring : ShelfMotionSpec.spring(.swap)
        return .spring(response: spring.response, dampingFraction: spring.damping)
            .delay(ShelfMotionSpec.entranceDelay(for: index, cascade: cascade))
    }

    // MARK: Transitions — each one says where the thing comes from; Reduce Motion keeps only the fade.

    private static func moving(_ transition: AnyTransition) -> AnyTransition {
        reduceMotion ? .opacity : transition
    }

    /// The main content area: views that come from below (preview, stack) rise, the cards settle down.
    static func content(from edge: Edge) -> AnyTransition {
        .asymmetric(
            insertion: moving(.opacity.combined(with: .offset(y: edge == .bottom ? 12 : -8))),
            removal: .opacity
        )
    }

    /// Paging through previews with the arrow keys: the next one slides in from the side you moved toward.
    static func page(direction: Int) -> AnyTransition {
        .asymmetric(
            insertion: moving(.opacity.combined(with: .offset(x: CGFloat(direction.signum()) * 16))),
            removal: .opacity
        )
    }

    /// A new card grows out of the strip's floor; a deleted one shrinks away in place.
    static var card: AnyTransition {
        moving(.asymmetric(
            insertion: .scale(scale: 0.88, anchor: .bottom).combined(with: .opacity),
            removal: .scale(scale: 0.86).combined(with: .opacity)
        ))
    }

    /// Small glyphs and badges (stars, clear buttons) pop in place.
    static var badge: AnyTransition { moving(.scale(scale: 0.6).combined(with: .opacity)) }

    /// List rows arrive from the end of the list and leave toward the leading edge.
    static var row: AnyTransition {
        moving(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
    }

    /// Popovers grow from the thing they belong to.
    static func popover(anchor: UnitPoint) -> AnyTransition {
        moving(.scale(scale: 0.94, anchor: anchor).combined(with: .opacity))
    }

    /// Inline status or error text below a control slides down from it.
    static var inlineNote: AnyTransition { moving(.offset(y: -4).combined(with: .opacity)) }
}

/// Cards near the front slide up in sequence when the shelf opens; later ones simply appear.
struct ShelfCardEntrance: ViewModifier {
    let index: Int
    let animates: Bool
    var cascade = true
    @State private var shown = false

    func body(content: Content) -> some View {
        let visible = shown || !animates
        let rise = ShelfMotion.reduceMotion ? 0 : ShelfMotionSpec.entranceRise(cascade: cascade)
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : rise)
            .onAppear {
                guard animates, !shown else { return }
                withAnimation(ShelfMotion.entrance(index, cascade: cascade)) { shown = true }
            }
    }
}

/// A popover that grows out of its anchor when it appears; its container handles the fade out.
struct ShelfPopoverEntrance: ViewModifier {
    var anchor: UnitPoint = .bottom
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown || ShelfMotion.reduceMotion ? 1 : 0.94, anchor: anchor)
            .onAppear { withAnimation(ShelfMotion.swap) { shown = true } }
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
                .scaleEffect(configuration.isPressed && !ShelfMotion.reduceMotion ? 0.92 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(ShelfMotion.lift, value: hovering)
                .animation(ShelfMotion.press, value: configuration.isPressed)
                .animation(ShelfMotion.lift, value: isActive)
        }
    }
}

/// Short-lived status text in the footer slides up and fades instead of popping.
enum ShelfToastTransition {
    static var transition: AnyTransition {
        .asymmetric(
            insertion: ShelfMotion.reduceMotion ? .opacity : .offset(y: 6).combined(with: .opacity),
            removal: .opacity
        )
    }
}
