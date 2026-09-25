import SwiftUI

// Liquid Glass (macOS 26) adoption. The deployment target stays macOS 14, so every use is behind
// `#available` with a fallback that reproduces the pre-26 look exactly.
//
// Deliberately NOT used in the status menu: on macOS 26 NSMenu already draws its own glass background,
// and layering glass on glass is the one thing Apple's guidance explicitly calls out as wrong.
//
// Also deliberately without `GlassEffectContainer`: it merges every glass shape within its spacing radius
// into one, which on the runner grid dissolved the per-card accent tint and blurred the selection
// checkmark into an unreadable smear. The container is for a small cluster of floating controls, not a grid.

extension View {
    /// Selectable card, as used by the runner grid. The selected card is tinted with the accent color.
    func glassCard(selected: Bool, cornerRadius: CGFloat = 10) -> some View {
        modifier(GlassCard(selected: selected, cornerRadius: cornerRadius))
    }

    /// Small rounded label (`Chip`).
    func glassBadge(tint: Color) -> some View {
        modifier(GlassBadge(tint: tint))
    }
}

private struct GlassCard: ViewModifier {
    let selected: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            // `.interactive()` gives the card the system's press and hover response.
            content.glassEffect(.regular.tint(selected ? Color.accentColor : nil).interactive(), in: shape)
        } else {
            content
                .background(shape.fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04)))
                .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08),
                                            lineWidth: selected ? 2 : 1))
        }
    }
}

private struct GlassBadge: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint.opacity(0.25)), in: Capsule())
        } else {
            content.background(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 0.5))
        }
    }
}
