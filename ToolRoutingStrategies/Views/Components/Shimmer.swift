import SwiftUI

// MARK: - Shimmer
//
// A band of brightness that sweeps across whatever it is applied to.
// Used on the status label while a turn is in flight.
//
// It replaces a spinner rather than joining one. A spinner says "busy"
// in a corner the eye has to find; shimmering the words themselves puts
// the motion where the reader is already looking, and reads as the text
// being alive rather than the app being blocked.
//
// Implemented as a MASK, so it modulates the label's own colour instead
// of painting over it — the text stays the right colour for the theme,
// in light mode and dark, and there is no blend mode to get wrong.
//
// The sweep is driven by the gradient's unit points rather than an
// offset, so it needs no GeometryReader and no knowledge of how wide the
// text is: a two-word label and a ten-word one take the same time to
// cross, which is what makes it look deliberate as the stage names
// change underneath it.

struct Shimmer: ViewModifier {
    /// Time for one pass. Slow enough to read as a sweep and not a
    /// flicker; fast enough that a 6-second wait shows several.
    var duration: Double = 1.4

    /// How dim the label goes outside the band. Not zero — text that
    /// vanishes and returns is a blink, and blinking text is a different,
    /// worse thing.
    var dimmed: Double = 0.35

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.6

    func body(content: Content) -> some View {
        if reduceMotion {
            // The label still says what is happening; it just says it
            // still. Motion is the decoration here, never the message.
            content
        } else {
            content
                .mask {
                    LinearGradient(
                        colors: [
                            .black.opacity(dimmed),
                            .black,
                            .black.opacity(dimmed),
                        ],
                        startPoint: UnitPoint(x: phase, y: 0.5),
                        endPoint: UnitPoint(x: phase + 0.6, y: 0.5)
                    )
                }
                .onAppear {
                    withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                        phase = 1.0
                    }
                }
        }
    }
}

extension View {
    /// Sweeps a band of brightness across this view, forever. For
    /// in-flight status only — on anything the user is meant to read at
    /// rest, it is just distraction.
    func shimmering(duration: Double = 1.4) -> some View {
        modifier(Shimmer(duration: duration))
    }
}
