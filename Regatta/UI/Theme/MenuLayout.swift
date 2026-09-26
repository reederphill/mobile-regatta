import SwiftUI

extension View {
    /// #25's readable-width single column: the full width on iPhone, centred and capped in a wide iPad window.
    /// The cap grows with Dynamic Type, so larger text keeps a similar line length.
    func readableColumn() -> some View {
        modifier(ReadableColumn())
    }

    /// A menu page's background and text colour, from `ChromePalette`, in place of a scroll view's or form's own.
    func menuBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(ChromePalette.background.ignoresSafeArea())
            .foregroundStyle(ChromePalette.text)
    }
}

private struct ReadableColumn: ViewModifier {
    // placeholder: about UIKit's readable content width at the default text size, until #169.
    @ScaledMetric(relativeTo: .body) private var maxWidth = 600.0

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 20)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}
