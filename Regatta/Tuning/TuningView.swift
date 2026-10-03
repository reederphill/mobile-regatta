#if DEBUG
import RegattaCore
import SwiftUI
import UIKit

/// The debug tuning panel (#232): a page on Home (and `-tuning`), and a sheet over a paused practice race.
/// Grouped sliders, each with its value and its file's, a reset per group, the files it tunes, saved tunings and
/// their export, and the tuned races kept on the device.
struct TuningView: View {
    let model: TuningModel
    @State private var saveName = ""
    @State private var export: ExportFiles?
    @State private var exportError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                status
                baseFiles
                ForEach(model.groups) { group in
                    TuningGroupView(group: group, model: model)
                }
                savedTunings
                tunedRaces
            }
            .padding(.vertical, 20)
            .readableColumn()
            // UI tests check the page was pushed.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("page-tuning")
        }
        .menuBackground()
        .navigationTitle("Tuning")
        .sheet(item: $export) { export in
            ShareSheet(items: export.urls)
        }
        .onDisappear(perform: model.saveNow)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.tuning.isTuned { TunedBadge(onChrome: true) }
                Text(model.tuning.isTuned ? "Differs from the files" : "Sailing the files as bundled")
                    .font(MenuFont.body(.subheadline))
                Spacer(minLength: 8)
                Button("Reset all", role: .destructive, action: model.resetAll)
                    .disabled(!model.tuning.isTuned)
                    .accessibilityIdentifier("tuning-reset-all")
            }
            Text("Data values become tuned copies of their files at the next practice race start; bots sail them too. Water, camera and boat values apply live. Never online.")
                .font(MenuFont.body(.footnote))
                .foregroundStyle(ChromePalette.text.opacity(0.75))
            ForEach(TuningSlot.allCases, id: \.self) { slot in
                if let problem = model.problems[slot] {
                    Label("\(slot.title): \(problem). The race sails the bundled file.", systemImage: "exclamationmark.triangle.fill")
                        .font(MenuFont.body(.footnote))
                        .accessibilityIdentifier("tuning-problem-\(slot.rawValue)")
                }
            }
        }
    }

    private var baseFiles: some View {
        TuningSection(title: "Files") {
            ForEach(TuningSlot.allCases, id: \.self) { slot in
                HStack {
                    Text(slot.title).font(MenuFont.body(.subheadline))
                    Spacer(minLength: 8)
                    let options = model.options(slot)
                    if options.count > 1 {
                        Picker(slot.title, selection: Binding(get: { model.tuning[base: slot] }, set: { model.setBase(slot, $0) })) {
                            ForEach(options, id: \.self) { Text($0.description).tag($0) }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Text(model.tuning[base: slot].description).font(MenuFont.body(.subheadline).monospaced())
                    }
                }
            }
            Text("Changing a file drops the values tuned into it.")
                .font(MenuFont.body(.caption))
                .foregroundStyle(ChromePalette.text.opacity(0.75))
        }
    }

    private var savedTunings: some View {
        TuningSection(title: "Saved tunings") {
            HStack {
                TextField("Name", text: $saveName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button("Save") {
                    model.save(as: saveName)
                    saveName = ""
                }
                .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(model.savedTunings, id: \.name) { saved in
                HStack {
                    Text(saved.name ?? "").font(MenuFont.body(.subheadline))
                    Spacer(minLength: 8)
                    Button("Load") { model.load(saved) }
                    Button(role: .destructive) {
                        model.delete(saved)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete \(saved.name ?? "")")
                }
            }
            Button {
                do {
                    let name = saveName.trimmingCharacters(in: .whitespaces)
                    export = ExportFiles(urls: try model.exportFiles(named: name.isEmpty ? "tuning" : name))
                } catch {
                    exportError = String(describing: error)
                }
            } label: {
                Label("Export as next versions…", systemImage: "square.and.arrow.up")
            }
            if let exportError {
                Label(exportError, systemImage: "exclamationmark.triangle.fill").font(MenuFont.body(.footnote))
            }
            Text("Exports each tuned file as its next version, ready for RegattaCore's Resources, with the changed values listed under placeholders, and the tuning itself.")
                .font(MenuFont.body(.caption))
                .foregroundStyle(ChromePalette.text.opacity(0.75))
        }
    }

    private var tunedRaces: some View {
        TuningSection(title: "Tuned races") {
            if model.races.isEmpty {
                Text("None yet. A practice race on tuned files is kept here, with its tuned copies beside its log, when it ends.")
                    .font(MenuFont.body(.footnote))
            }
            ForEach(model.races, id: \.self) { race in
                HStack {
                    Text(race.lastPathComponent).font(MenuFont.body(.footnote).monospaced())
                    Spacer(minLength: 8)
                    ShareLink(items: model.files(ofRace: race)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share \(race.lastPathComponent)")
                }
            }
            if !model.races.isEmpty {
                Text("Replay one with regatta-replay <folder>.")
                    .font(MenuFont.body(.caption))
                    .foregroundStyle(ChromePalette.text.opacity(0.75))
            }
        }
    }
}

/// One group's sliders under its title, with where they apply and a reset.
private struct TuningGroupView: View {
    let group: TuningGroup
    let model: TuningModel

    var body: some View {
        TuningSection(title: group.title, tag: tag, trailing: {
            if group.applies != .later {
                Button("Reset") { model.reset(group) }
                    .disabled(!model.isChanged(group))
                    .accessibilityIdentifier("tuning-reset-\(group.id)")
            }
        }) {
            Text(group.note)
                .font(MenuFont.body(.caption))
                .foregroundStyle(ChromePalette.text.opacity(0.75))
            if group.id == TuningCatalog.pressureOverlayGroup {
                Toggle("Show the pressure field", isOn: Binding(get: { model.showsPressure }, set: { model.showsPressure = $0 }))
                    .font(MenuFont.body(.subheadline))
                    .tint(ChromePalette.tint)
                    .accessibilityIdentifier("tuning-shows-pressure")
            }
            if group.id == TuningCatalog.shadowDrawingGroup {
                Picker("Draw the shadow as", selection: Binding(get: { model.shadowDrawing }, set: { model.shadowDrawing = $0 })) {
                    Text("Cones").tag(ShadowDrawing.cones)
                    Text("Trails").tag(ShadowDrawing.trails)
                    Text("Both").tag(ShadowDrawing.both)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("tuning-shadow-drawing")
            }
            ForEach(group.sliders) { slider in
                TuningSliderRow(slider: slider, model: model)
            }
            ForEach(group.later) { later in
                HStack {
                    Text(later.title).font(MenuFont.body(.subheadline))
                    Spacer()
                    Text("with \(later.ticket)").font(MenuFont.body(.caption))
                }
                .foregroundStyle(ChromePalette.text.opacity(0.6))
            }
        }
        .accessibilityIdentifier("tuning-group-\(group.id)")
    }

    private var tag: String? {
        switch group.applies {
        case .nextRace: "Next race"
        case .live: "Live"
        case .later: nil
        }
    }
}

/// A slider with its value, its file's value, and a reset once it differs.
private struct TuningSliderRow: View {
    let slider: TuningSlider
    let model: TuningModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let file = model.fileValue(slider), let value = model.value(slider) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(slider.title).font(MenuFont.body(.subheadline))
                    Spacer(minLength: 8)
                    Text(slider.format(value))
                        .font(MenuFont.number(.subheadline))
                        .foregroundStyle(model.isChanged(slider) ? ChromePalette.tint : ChromePalette.text)
                    if model.isChanged(slider) {
                        Button {
                            model.reset(slider)
                        } label: {
                            Image(systemName: "arrow.uturn.backward.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Reset \(slider.title)")
                    }
                }
                Slider(value: Binding(get: { value }, set: { model.set(slider, to: $0) }),
                       in: min(slider.range.lowerBound, file)...max(slider.range.upperBound, file))
                    .accessibilityLabel(slider.title)
                    .accessibilityValue(slider.format(value))
                HStack {
                    Text("File \(slider.format(file))")
                    Spacer()
                    if case .groove(let column) = slider.target, let groove = model.grooves[column] {
                        Text("Groove \(String(format: "%.1f", groove))°")
                    }
                }
                .font(MenuFont.body(.caption))
                .foregroundStyle(ChromePalette.text.opacity(0.75))
            } else {
                HStack {
                    Text(slider.title).font(MenuFont.body(.subheadline))
                    Spacer()
                    Text("Not in this file").font(MenuFont.body(.caption))
                }
                .foregroundStyle(ChromePalette.text.opacity(0.6))
            }
        }
        .padding(.vertical, 4)
    }
}

/// A titled panel on the page's surface colour.
private struct TuningSection<Trailing: View, Content: View>: View {
    let title: String
    var tag: String?
    var trailing: Trailing
    var content: Content

    init(title: String, tag: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.tag = tag
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(MenuFont.heading(.headline))
                if let tag {
                    Text(tag)
                        .font(MenuFont.body(.caption2).weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(ChromePalette.text.opacity(0.5)))
                }
                Spacer(minLength: 8)
                trailing
            }
            content
        }
        .padding(16)
        .background(ChromePalette.surface, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}

/// "TUNED" (#232): the race, or the panel, differs from the bundled files or the standard look. Its own overlay
/// over the race, white on translucent black like the rest of the HUD chrome (#22); `onChrome` draws it for
/// the menus instead.
struct TunedBadge: View {
    var onChrome = false

    var body: some View {
        Label("TUNED", systemImage: "slider.horizontal.3")
            .font(.caption.weight(.heavy))
            .tracking(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(onChrome ? AnyShapeStyle(ChromePalette.surface) : AnyShapeStyle(Color.black.opacity(0.5)), in: .capsule)
            .overlay(Capsule().strokeBorder(onChrome ? ChromePalette.tint : .white.opacity(0.8), lineWidth: 1))
            .foregroundStyle(onChrome ? ChromePalette.tint : .white)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tuned")
            .accessibilityIdentifier("tuned-badge")
    }
}

/// Files for the share sheet.
private struct ExportFiles: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// The system share sheet over several files at once.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
