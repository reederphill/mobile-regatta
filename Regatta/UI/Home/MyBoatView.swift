import RegattaCore
import SwiftUI

/// My boat (#136, #25): the livery editor and shop on one page, pushed from home. A large render of the draft, the
/// designs (starter, earned, shop), the colour slots from the safe palette and the sail number, then one button: Save,
/// or Buy for a paid design you don't own. Sparse and short words (owner, 2026-10-02); copy is TODO-COPY (#171).
struct MyBoatView: View {
    @Bindable var model: MyBoatModel
    @FocusState private var numberFocused: Bool

    /// Thumbnails draw one fixed number, illegible at their size, so typing one redraws only the large render.
    private static let thumbnailNumber = 1
    private static let thumbnailSize = CGSize(width: 84, height: 40)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LiveryRenderView(livery: model.draft)
                    .accessibilityIdentifier("myboat-render")
                    .frame(maxWidth: .infinity)

                if model.isFleetLocked {
                    note("Locked for this race")  // TODO-COPY (#171)
                }

                Group {
                    designSection("Starter") { $0.acquisition.isFree }
                    designSection("Earned") { if case .earned = $0.acquisition { true } else { false } }
                    designSection("Shop") { if case .paid = $0.acquisition { true } else { false } }

                    if let design = model.selectedDesign {
                        ForEach(LiverySlot.allCases.filter(design.slots.contains), id: \.self) { slot in
                            colourRow(slot)
                        }
                    }

                    numberRow
                }
                .disabled(model.isFleetLocked)
            }
            .padding(.vertical, 20)
            .readableColumn()
            // UI tests check the page was pushed.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("page-myboat")
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { actionBar }
        .menuBackground()
        .navigationTitle("My boat")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { numberFocused = false }
                    .accessibilityIdentifier("myboat-done")
            }
        }
        // Leaving the page discards the draft; a purchase in progress carries on (`MyBoatModel.buy`).
        .onDisappear { model.discardDraft() }
    }

    // MARK: - Designs

    private func designSection(_ title: String, _ includes: (LiveryDesign) -> Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(MenuFont.heading(.headline))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.thumbnailSize.width), spacing: 10)], spacing: 10) {
                ForEach(model.designs.filter(includes), id: \.id) { design in
                    designButton(design)
                }
            }
        }
    }

    private func designButton(_ design: LiveryDesign) -> some View {
        let selected = design.id == model.design
        let caption = model.caption(for: design)
        return Button { model.select(design.id) } label: {
            VStack(spacing: 4) {
                LiveryRenderView(livery: model.draft(on: design, sailNumber: Self.thumbnailNumber),
                                 size: Self.thumbnailSize)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(ChromePalette.tint, lineWidth: selected ? 3 : 0)
                    }
                    .accessibilityHidden(true)
                Text(caption ?? " ")
                    .font(MenuFont.body(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([MyBoatModel.name(of: design), caption].compactMap(\.self).joined(separator: ", "))
        .accessibilityValue(selected ? "selected" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("myboat-design-\(design.id.rawValue)")
    }

    // MARK: - Colours

    /// A slot's name. TODO-COPY (#171)
    private static func title(_ slot: LiverySlot) -> String {
        switch slot {
        case .deck: "Deck"
        case .accent: "Accent"
        case .sail: "Sail"
        }
    }

    private func colourRow(_ slot: LiverySlot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.title(slot)).font(MenuFont.heading(.headline))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(model.swatches(for: slot), id: \.id) { swatch in
                    let selected = model.colours[slot] == swatch.id
                    Button { model.setColour(swatch.id, for: slot) } label: {
                        Circle()
                            .fill(Color(uiColor: UIColor(rgb: swatch.rgb)))
                            .overlay { Circle().strokeBorder(ChartPalette.markEdge.color, lineWidth: 1) }
                            .padding(4)
                            .overlay { Circle().strokeBorder(ChromePalette.tint, lineWidth: selected ? 3 : 0) }
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(MyBoatModel.name(of: swatch.id))
                    .accessibilityValue(selected ? "selected" : "")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("myboat-colour-\(slot.rawValue)-\(swatch.id.rawValue)")
                }
            }
        }
    }

    // MARK: - Number

    private var numberRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Number").font(MenuFont.heading(.headline))  // TODO-COPY (#171)
            TextField("Number", text: $model.numberText)
                .keyboardType(.numberPad)
                .focused($numberFocused)
                .font(MenuFont.number(.title3))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 140)
                .accessibilityIdentifier("myboat-number")
            if model.sailNumber == nil {
                note("1 to 9999")  // TODO-COPY (#171)
                    .accessibilityIdentifier("myboat-number-hint")
            }
        }
    }

    // MARK: - The button

    private var actionBar: some View {
        let action = model.action
        return VStack(spacing: 6) {
            if let note = model.purchaseNote {
                self.note(note).accessibilityIdentifier("myboat-note")
            }
            Button {
                numberFocused = false
                switch action {
                case .save: model.save()
                case .buy: model.buy()
                default: break
                }
            } label: {
                Text(action.title)
                    .font(MenuFont.heading(.title3))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!action.isEnabled || model.isBuying)
            .accessibilityIdentifier("myboat-action")
        }
        .padding(.vertical, 12)
        .readableColumn()
        .background(ChromePalette.background.opacity(0.95).ignoresSafeArea())
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(MenuFont.body(.footnote))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
