import SwiftUI

/// A label and a segmented picker, for Settings (#110) and the pause menu (#314). The picker takes the row's spare
/// width up to `maxPickerWidth` rather than its ideal size, so the label keeps room; at accessibility text sizes the
/// label stacks above a full-width picker, as side by side neither would fit.
struct SegmentedPickerRow<Value: Hashable & CaseIterable>: View where Value.AllCases: RandomAccessCollection {
    static var maxPickerWidth: CGFloat { 220 }

    let title: String
    var titleFont: Font?
    @Binding var selection: Value
    let id: String
    let label: (Value) -> String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(titleFont)
                picker.frame(maxWidth: .infinity)
            }
        } else {
            HStack {
                Text(title).font(titleFont)
                Spacer(minLength: 12)
                picker.frame(maxWidth: Self.maxPickerWidth)
            }
        }
    }

    private var picker: some View {
        Picker(title, selection: $selection) {
            ForEach(Array(Value.allCases), id: \.self) { Text(label($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(id)
    }
}
