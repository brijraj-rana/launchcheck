import AppKit
import SwiftUI

/// One motion scale for the whole app, after the token scale at transitions.dev: a handful of durations,
/// one decisive curve, small distances and a light blur. Every animation in the app is built from these.
enum Motion {
    static let stagger = 0.04
    static let micro = 0.08
    static let quick = 0.15
    static let fast = 0.25
    static let slow = 0.4
    static let verySlow = 0.5

    static let distanceMicro: CGFloat = 4
    static let distanceMedium: CGFloat = 12
    static let blurSmall: CGFloat = 2
    static let blurMedium: CGFloat = 3

    /// Starts fast and settles gently. For anything that opens, slides or changes size.
    static func smoothOut(_ duration: Double) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    /// A button going down under the pointer.
    static let press = smoothOut(quick)
    /// A sliding underline or pill, a section opening.
    static let move = smoothOut(fast)
    /// A label or a panel changing in place.
    static let swap = Animation.easeInOut(duration: quick)
    /// The one emphasis moment: the score drawing itself.
    static let reveal = smoothOut(verySlow)

    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Animates a change, or just makes it when the system asks for less motion.
    @MainActor static func run(_ animation: Animation, _ change: () -> Void) {
        if reduced { change() } else { withAnimation(animation, change) }
    }
}

// MARK: Transitions

private struct Veil: ViewModifier {
    let blur: CGFloat
    let y: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.blur(radius: blur).offset(y: y).opacity(opacity)
    }
}

extension AnyTransition {
    /// Text swap: the old words leave upward and the new arrive from below, through a light blur.
    static var swap: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Veil(blur: Motion.blurSmall, y: Motion.distanceMicro, opacity: 0), identity: Veil(blur: 0, y: 0, opacity: 1)),
            removal: .modifier(active: Veil(blur: Motion.blurSmall, y: -Motion.distanceMicro, opacity: 0), identity: Veil(blur: 0, y: 0, opacity: 1))
        )
    }

    /// Soft swap: one thing dissolves into the next in place, with no movement.
    static var soft: AnyTransition {
        .modifier(active: Veil(blur: Motion.blurSmall, y: 0, opacity: 0), identity: Veil(blur: 0, y: 0, opacity: 1))
    }
}

/// A short label that changes in place: "Copy as task" to "Copied".
struct SwapText: View {
    let text: String

    var body: some View {
        ZStack {
            Text(text).id(text).transition(.swap)
        }
        .animation(Motion.reduced ? nil : Motion.swap, value: text)
    }
}

// MARK: Arrival

/// Texts reveal: stacked blocks rise into place one after another, once, when a new report lands.
private struct Rise: ViewModifier {
    let shown: Bool
    let order: Int

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : Motion.blurMedium)
            .offset(y: shown ? 0 : Motion.distanceMedium)
            .animation(Motion.smoothOut(Motion.verySlow).delay(Double(order) * Motion.stagger * 2), value: shown)
    }
}

extension View {
    func rise(_ shown: Bool, order: Int) -> some View {
        modifier(Rise(shown: shown, order: order))
    }

    /// Shimmer text: a band of light crossing words that describe work still going on.
    func shimmer() -> some View {
        modifier(Shimmer())
    }

    /// Error shake: four short legs, each easing out, then still.
    func shake(on trigger: Int) -> some View {
        modifier(Shake(trigger: trigger))
    }
}

private struct Shimmer: ViewModifier {
    @State private var travel: CGFloat = -0.6
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        if Motion.reduced || isSnapshot {
            content
        } else {
            content
                .opacity(0.55)
                .overlay {
                    GeometryReader { geometry in
                        LinearGradient(colors: [.clear, Color.primary, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.6)
                            .offset(x: travel * geometry.size.width)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { travel = 1 }
                }
        }
    }
}

private struct Shake: ViewModifier {
    let trigger: Int

    func body(content: Content) -> some View {
        if Motion.reduced {
            content
        } else {
            content.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(6, duration: 0.08)
                    CubicKeyframe(-6, duration: 0.06)
                    CubicKeyframe(4, duration: 0.08)
                    CubicKeyframe(0, duration: 0.06)
                }
            }
        }
    }
}
