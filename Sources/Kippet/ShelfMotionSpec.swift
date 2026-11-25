import Foundation

/// The numbers behind the shelf's motion language, kept free of SwiftUI so they can be tested.
///
/// Every state change maps to one of these roles. Repeated actions (pressing, moving the selection)
/// use the shortest springs; one-off changes (opening the shelf, swapping the content area) may take
/// a little longer because they explain where something came from.
enum ShelfMotionSpec {
    struct Spring: Equatable, Sendable {
        let response: Double
        let damping: Double
    }

    enum Role: CaseIterable, Sendable {
        /// Button press and release.
        case press
        /// Keyboard or click selection, focus rings: done many times in a row.
        case select
        /// Hover, toggles, small badges appearing.
        case lift
        /// A highlight or scroll position moving from one place to another.
        case glide
        /// Replacing the main content area or a popover appearing.
        case swap
        /// Rows or cards inserted into or removed from a list.
        case list
    }

    static func spring(_ role: Role) -> Spring {
        switch role {
        case .press: Spring(response: 0.18, damping: 0.72)
        case .select: Spring(response: 0.24, damping: 0.86)
        case .lift: Spring(response: 0.28, damping: 0.8)
        case .glide: Spring(response: 0.32, damping: 0.88)
        case .swap: Spring(response: 0.32, damping: 0.9)
        case .list: Spring(response: 0.36, damping: 0.86)
        }
    }

    /// Under Reduce Motion every change becomes a short dissolve with no movement.
    static let reducedFade: Double = 0.15
    /// Crossfades for content that arrives on its own (a decoded image, a new text value).
    static let fade: Double = 0.18

    // MARK: Opening the shelf

    /// The cascade's delay stops growing after this many cards, so the wave stays short.
    static let entranceCount = 8
    /// Every card that can be on screen at once, even on a wide display, fades in with the others;
    /// cards built later by scrolling just appear.
    static let entranceLimit = 16
    static let entranceDelay: Double = 0.02
    static let entranceStep: Double = 0.022
    static let entranceSpring = Spring(response: 0.38, damping: 0.84)
    /// How long after a reveal newly built cards still count as part of the cascade.
    static let entranceWindow: Double = 0.5

    static func entranceAnimates(index: Int, secondsSinceReveal: Double) -> Bool {
        index >= 0 && index < entranceLimit && secondsSinceReveal >= 0 && secondsSinceReveal < entranceWindow
    }

    /// Opening cascades from the left; switching boards settles every card at once, because the
    /// board highlight is already showing the move and a second wave would compete with it.
    static func entranceDelay(for index: Int, cascade: Bool = true) -> Double {
        guard cascade else { return 0 }
        return entranceDelay + Double(min(max(index, 0), entranceCount - 1)) * entranceStep
    }

    /// How far a card rises while it fades in.
    static func entranceRise(cascade: Bool) -> Double { cascade ? 14 : 6 }

    // MARK: Window

    static let windowRise: Double = 20
    static let windowRiseDuration: Double = 0.28
    static let windowSink: Double = 10
    static let windowSinkDuration: Double = 0.14
    /// Expo-like ease out: fast start, long soft landing.
    static let windowRiseCurve: (Float, Float, Float, Float) = (0.16, 1, 0.3, 1)
    /// Quick ease in for leaving: it gets out of the way instead of lingering.
    static let windowSinkCurve: (Float, Float, Float, Float) = (0.32, 0, 0.67, 0)

    /// Reopening while the shelf is still sinking continues from where it is, scaled to the distance left.
    static func riseDuration(remainingFraction: Double) -> Double {
        let fraction = min(max(remainingFraction, 0), 1)
        return max(0.12, windowRiseDuration * fraction)
    }

    // MARK: Sync indicator

    /// When syncing stops mid-turn the arrows finish the turn forward instead of snapping back.
    static func restingAngle(after angle: Double) -> Double {
        guard angle.isFinite, angle > 0 else { return 0 }
        return (angle / 360).rounded(.up) * 360
    }
}
