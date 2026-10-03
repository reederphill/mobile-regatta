import RegattaCore
import SwiftUI

/// My boat (#136, #25): the livery editor and shop on one page, pushed from home. The draft's render stays pinned at
/// the top; under it a segmented control picks one part at a time (Decal, Colours, Sail, Number), and only that part
/// scrolls. One button at the bottom: Save, or Buy for a paid design you don't own. Sparse and short words (owner,
/// 2026-10-02; owner review of #382); copy is TODO-COPY (#171).
struct MyBoatView: View {
    @Bindable var model: MyBoatModel
    @FocusState private var numberFocused: Bool

    /// Thumbnails draw one fixed number, illegible at their size, so typing one redraws only the large render.
    private static let thumbnailNumber = 1
    private static let thumbnailSize = CGSize(width: 84, height: 40)

    var body: some View {
        VStack(spacing: 0) {
            // Pinned: the render and the part picker never scroll away.
            VStack(spacing: 12) {
                LiveryRenderView(livery: model.draft)
                    .accessibilityIdentifier("myboat-render")
                    .frame(maxWidth: .infinity)

                if model.isFleetLocked {
                    note("Locked for this race")  // TODO-COPY (#171)
                }

                Picker("Part", selection: $model.section) {  // TODO-COPY (#171)
                    ForEach(MyBoatModel.Section.allCases, id: \.self) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("myboat-section")
                .disabled(model.isFleetLocked)
            }
            .padding(.top, 12)
            .padding(.bottom, 8)
            .readableColumn()

            ScrollView {
                Group {
                    switch model.section {
                    case .decal: designList
                    case .colours: coloursSection
                    case .sail: sailSection
                    case .number: numberRow
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .readableColumn()
                .disabled(model.isFleetLocked)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        // UI tests check the page was pushed.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page-myboat")
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

    // MARK: - Decal

    /// One plain list, no headings: owned, then earned, then paid (`MyBoatModel.listedDesigns`).
    private var designList: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.thumbnailSize.width), spacing: 10)], spacing: 10) {
            ForEach(model.listedDesigns, id: \.id) { design in
                designButton(design)
            }
        }
    }

    private func designButton(_ design: LiveryDesign) -> some View {
        let selected = design.id == model.design
        let caption = model.caption(for: design)
        let mark = model.mark(for: design)
        return Button { model.select(design.id) } label: {
            VStack(spacing: 4) {
                LiveryRenderView(livery: model.draft(on: design, sailNumber: Self.thumbnailNumber),
                                 size: Self.thumbnailSize)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(ChromePalette.tint, lineWidth: selected ? 3 : 0)
                    }
                    .overlay(alignment: .topTrailing) {
                        if let mark {
                            Image(systemName: mark == .price ? "tag.fill" : "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(4)
                        }
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
        .accessibilityLabel(accessibilityLabel(design, mark: mark))
        .accessibilityValue(selected ? "selected" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("myboat-design-\(design.id.rawValue)")
    }

    /// The design's name, then its price or "Locked" and its races.
    private func accessibilityLabel(_ design: LiveryDesign, mark: MyBoatModel.Mark?) -> String {
        var parts = [MyBoatModel.name(of: design)]
        switch mark {
        case .price: parts += model.price(of: design).map { [$0] } ?? []
        case .lock:
            parts.append("Locked")  // TODO-COPY (#171)
            if case .earned(let needed) = design.acquisition {
                parts.append("\(min(model.completedRaces, needed)) / \(needed) races")
            }
        case nil: break
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Colours and sail

    /// Deck and accent (three-slot designs only).
    private var coloursSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach([LiverySlot.deck, .accent].filter { model.selectedDesign?.slots.contains($0) == true },
                    id: \.self) { slot in
                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.title(slot)).font(MenuFont.heading(.headline))
                    swatches(slot)
                }
            }
        }
    }

    /// The sail colour, and the design's sail graphic, which comes with its decal.
    private var sailSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            swatches(.sail)
            if let graphic = model.selectedDesign?.sailGraphic, graphic != LiveryArt.SailGraphic.plain.rawValue {
                note("Graphic: \(MyBoatModel.name(ofGraphic: graphic))")  // TODO-COPY (#171)
                    .accessibilityIdentifier("myboat-graphic")
            }
        }
    }


    /// A slot's name. TODO-COPY (#171)
    private static func title(_ slot: LiverySlot) -> String {
        switch slot {
        case .deck: "Deck"
        case .accent: "Accent"
        case .sail: "Sail"
        }
    }

    /// `slot`'s safe-palette swatches.
    private func swatches(_ slot: LiverySlot) -> some View {
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

    // MARK: - Number

    private var numberRow: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        let enabled = action.isEnabled && !model.isBuying
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
                    // The page's `menuBackground` text colour would otherwise reach the label: navy on the navy fill.
                    .foregroundStyle(enabled ? AnyShapeStyle(ChromePalette.onTint) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!enabled)
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
