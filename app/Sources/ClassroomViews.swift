import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Style

/// Classroom surfaces reuse the app's design tokens; only the accent and the
/// three class colours are new.
enum ClassroomStyle {
    static let accent = NotchDesign.Palette.accent
    static let accentSoft = NotchDesign.Palette.accent.opacity(0.12)
    static let good = Color(red: 0.188, green: 0.820, blue: 0.349)
    static let bad = Color(red: 1.0, green: 0.271, blue: 0.231)
    static let warning = Color(red: 1.0, green: 0.620, blue: 0.039)
    static let violet = Color(red: 0.620, green: 0.549, blue: 1.0)

    static let pageTitle = NotchDesign.Typography.pageTitle
    static let pageSubtitle = NotchDesign.Typography.pageSubtitle
    static let cardTitle = NotchDesign.Typography.cardTitle
    static let body = NotchDesign.Typography.body
    static let caption = NotchDesign.Typography.caption
    static let eyebrow = NotchDesign.Typography.eyebrow
    static let value = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let mono = Font.system(size: 10.5, design: .monospaced)

    static func classColor(_ index: Int) -> Color {
        switch index % 5 {
        case 0: return good
        case 1: return warning
        case 2: return accent
        case 3: return violet
        default: return bad
        }
    }
}

// MARK: - Components

/// Uses the actual proposed width instead of the ideal width of cards containing
/// wrapped text, canvases and scroll views. Those ideal sizes are not reliable
/// candidates for ViewThatFits and can push a settings page outside its window.
struct ClassroomColumn: LayoutValueKey {
    static let defaultValue = 0
}

struct ClassroomColumns: Layout {
    var leadingWidth: CGFloat = 330
    var trailingWidth: CGFloat? = nil
    var minimumWidth: CGFloat = 700
    var spacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? minimumWidth)
        let sizes = sizes(width: width, subviews: subviews)
        var heights = [CGFloat.zero, CGFloat.zero]
        for (index, subview) in subviews.enumerated() {
            let column = width >= minimumWidth ? subview[ClassroomColumn.self] : 0
            if heights[column] > 0 { heights[column] += spacing }
            heights[column] += sizes[index].height
        }
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(width: bounds.width, subviews: subviews)
        var offsets = [CGFloat.zero, CGFloat.zero]
        for (index, subview) in subviews.enumerated() {
            let column = bounds.width >= minimumWidth ? subview[ClassroomColumn.self] : 0
            let x = column == 0 ? bounds.minX : bounds.maxX - sizes[index].width
            subview.place(at: CGPoint(x: x, y: bounds.minY + offsets[column]),
                          anchor: .topLeading, proposal: ProposedViewSize(sizes[index]))
            offsets[column] += sizes[index].height + spacing
        }
    }

    private func sizes(width: CGFloat, subviews: Subviews) -> [CGSize] {
        subviews.map { subview in
            let firstWidth = trailingWidth.map { max(0, width - $0 - spacing) } ?? leadingWidth
            let columnWidth = width >= minimumWidth
                ? (subview[ClassroomColumn.self] == 0 ? firstWidth : max(0, width - firstWidth - spacing))
                : width
            let measured = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            return CGSize(width: columnWidth, height: measured.height)
        }
    }
}

/// Wrap related actions and class chips without shrinking their hit targets.
struct ClassroomFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 700, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.frames[index].minX,
                                     y: bounds.minY + result.frames[index].minY),
                          anchor: .topLeading, proposal: ProposedViewSize(result.frames[index].size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), frames)
    }
}

struct ClassroomCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

struct ClassroomCardTitle: View {
    let text: String
    var detail: String? = nil
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(text))
                    .font(ClassroomStyle.cardTitle)
                    .foregroundStyle(NotchDesign.Palette.text)
                if let detail {
                    Text(LocalizedStringKey(detail))
                        .font(ClassroomStyle.caption)
                        .foregroundStyle(NotchDesign.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let trailing { trailing }
        }
    }
}

struct ClassroomDivider: View {
    var body: some View {
        Rectangle().fill(NotchDesign.Palette.hairline).frame(height: 1)
    }
}

struct ClassroomPrimaryButton: View {
    let title: String
    var symbol: String? = nil
    var enabled: Bool = true
    var tint: Color = ClassroomStyle.accent
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                }
                Text(LocalizedStringKey(title))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                enabled ? tint : tint.opacity(0.35),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct ClassroomSecondaryButton: View {
    let title: String
    var symbol: String? = nil
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                }
                Text(LocalizedStringKey(title)).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(NotchDesign.Palette.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                NotchDesign.Palette.track,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

struct ClassroomChip: View {
    let title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : NotchDesign.Palette.text)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(
                    selected ? NotchDesign.Palette.selected : NotchDesign.Palette.track,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ClassroomStatusChip: View {
    let text: String
    var tint: Color = NotchDesign.Palette.secondaryText
    var filled: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(LocalizedStringKey(text))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(filled ? Color.white : NotchDesign.Palette.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(filled ? tint : NotchDesign.Palette.track, in: Capsule())
    }
}

struct ClassroomStatTile: View {
    let title: String
    let value: String
    var tint: Color = NotchDesign.Palette.text
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(NotchDesign.Palette.eyebrow)
                .lineLimit(1)
            Text(value)
                .font(ClassroomStyle.value)
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
            if let note {
                Text(LocalizedStringKey(note))
                    .font(.system(size: 10))
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            NotchDesign.Palette.track,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }
}

struct ClassroomInfoRow: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotchDesign.Palette.secondaryText)
                .frame(width: 16)
            Text(LocalizedStringKey(title))
                .font(.system(size: 11.5))
                .foregroundStyle(NotchDesign.Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct ClassroomEmptyState: View {
    let title: String
    let message: String
    var symbol: String = "sparkles"

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(NotchDesign.Palette.eyebrow)
            Text(LocalizedStringKey(title))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NotchDesign.Palette.text)
            Text(LocalizedStringKey(message))
                .font(.system(size: 11))
                .foregroundStyle(NotchDesign.Palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
    }
}

// MARK: - Step bar

struct ClassroomStepBar: View {
    @ObservedObject var store: ClassroomStore

    var body: some View {
        // Keep all six destinations visible, including at the minimum window
        // width. A single row of labels has an intrinsic width wider than it.
        ViewThatFits(in: .horizontal) {
            stepGrid(columns: 6).frame(minWidth: 760)
            stepGrid(columns: 3)
        }
        .padding(8)
        .background(
            NotchDesign.Palette.card,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(NotchDesign.Palette.hairline, lineWidth: 1)
        }
    }

    private func stepGrid(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
            ForEach(ClassroomStep.allCases) { step in
                item(step)
            }
        }
    }

    private func item(_ step: ClassroomStep) -> some View {
        let isCurrent = store.step == step
        let isDone = step.rawValue < store.step.rawValue
        return Button {
            store.step = step
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(isCurrent ? ClassroomStyle.accent
                              : (isDone ? NotchDesign.Palette.selected : Color.clear))
                    Circle()
                        .strokeBorder(
                            isCurrent || isDone ? Color.clear : NotchDesign.Palette.hairline,
                            lineWidth: 1
                        )
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Text("\(step.number)")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(isCurrent ? .white : NotchDesign.Palette.secondaryText)
                    }
                }
                .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 0) {
                    Text(LocalizedStringKey(step.title))
                        .font(.system(size: 10.5, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? NotchDesign.Palette.text : NotchDesign.Palette.secondaryText)
                        .lineLimit(1)
                    Text(status(step))
                        .font(.system(size: 9))
                        .foregroundStyle(isCurrent ? ClassroomStyle.accent : NotchDesign.Palette.eyebrow)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(
                isCurrent ? NotchDesign.Palette.track : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("classroom.step.\(step.rawValue)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .help(store.t(step.title))
    }

    private func status(_ step: ClassroomStep) -> String {
        switch step {
        case .dataset: return store.photos(store.images.count)
        case .annotate: return "\(store.labeledCount)/\(store.images.count)"
        case .train: return store.progress.isRunning ? store.t("Training…") : store.t("Ready")
        case .records: return "\(store.runs.count)"
        case .test: return store.t("Inference")
        case .export: return store.t("Package")
        }
    }
}

// MARK: - Page

struct ClassroomPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ClassroomStore

    var body: some View {
        SettingsPage(
            title: "Training",
            subtitle: "Train a model on your own photos, one step at a time: dataset, annotation, training, comparison, testing, apply."
        ) {
            ClassroomStepBar(store: store)

            if let banner = store.banner {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").font(.system(size: 11))
                    Text(banner).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(store.t("Turn Off")) { store.banner = nil }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ClassroomStyle.accent)
                }
                .foregroundStyle(NotchDesign.Palette.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    ClassroomStyle.accentSoft,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }

            header

            switch store.step {
            case .dataset: ClassroomDatasetStep(store: store)
            case .annotate: ClassroomAnnotateStep(store: store)
            case .train: ClassroomTrainStep(store: store)
            case .records: ClassroomRecordsStep(store: store)
            case .test: ClassroomTestStep(store: store)
            case .export: ClassroomExportStep(store: store, training: model.training)
            }

            footer
        }
        .task { store.probeCapabilities() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text("\(store.step.number)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(ClassroomStyle.accent, in: Circle())
                Text(LocalizedStringKey(store.step.title))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(NotchDesign.Palette.text)
            }
            Text(LocalizedStringKey(store.step.blurb))
                .font(.system(size: 11.5))
                .foregroundStyle(NotchDesign.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(hint))
                .font(ClassroomStyle.caption)
                .foregroundStyle(NotchDesign.Palette.secondaryText)
                .lineLimit(2)
            Spacer(minLength: 10)
            ClassroomSecondaryButton(
                title: "Back",
                symbol: "chevron.left",
                enabled: store.step.rawValue > 0
            ) {
                if let previous = ClassroomStep(rawValue: store.step.rawValue - 1) {
                    store.step = previous
                }
            }
            ClassroomPrimaryButton(
                title: "Next",
                symbol: "chevron.right",
                enabled: store.step != .export
            ) {
                if let next = ClassroomStep(rawValue: store.step.rawValue + 1) {
                    store.step = next
                }
            }
            .frame(width: 96)
        }
        .padding(.top, 2)
    }

    private var hint: String {
        switch store.step {
        case .dataset:
            if store.datasetReady {
                return store.t("Dataset ready — next, box every photo.")
            }
            return store.stepOneReady
                ? store.t("Photos are in — press Build dataset to lay them out for training.")
                : store.t("You need at least two classes, each with photos.")
        case .annotate:
            return String(format: store.t("%d of %d done"), store.labeledCount, store.images.count)
        case .train:
            return store.progress.isRunning
                ? store.t("The model is practising; good time for a water break.")
                : store.t("Press Start training to begin.")
        case .records:
            return store.t("Pick a run on the left to see details; compare up to 3 at once.")
        case .test:
            return store.t("Quiz the model with photos it has never seen.")
        case .export:
            return store.t("Export CoreML and apply it to this app.")
        }
    }
}

// MARK: - Step 1

struct ClassroomDatasetStep: View {
    @ObservedObject var store: ClassroomStore

    var body: some View {
        ClassroomColumns {
            sourcesCard
            checkCard.layoutValue(key: ClassroomColumn.self, value: 1)
            tipsCard
        }
    }

    private var sourcesCard: some View {
        ClassroomCard {
            ClassroomCardTitle(text: "Photo sources", detail: "At least 3 photos per class, with similar lighting.")

            ForEach(Array(store.classes.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    Circle().fill(item.color).frame(width: 8, height: 8)

                    TextField("", text: Binding(
                        get: { store.displayName(item.name) },
                        set: { store.renameClass(at: index, to: $0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(NotchDesign.Palette.text)
                    .frame(width: 92)

                    Text(store.photos(store.images.filter { $0.className == index }.count))
                        .font(.system(size: 10.5))
                        .foregroundStyle(NotchDesign.Palette.secondaryText)
                        .lineLimit(1)
                        .frame(width: 62, alignment: .leading)

                    Spacer(minLength: 0)

                    Button {
                        importImages(className: index)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(NotchDesign.Palette.text)
                            .frame(width: 22, height: 20)
                            .background(
                                NotchDesign.Palette.track,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(store.t("Add photos"))

                    Button {
                        store.removeClass(at: index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(NotchDesign.Palette.secondaryText)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.classes.count <= 2)
                    .opacity(store.classes.count <= 2 ? 0.35 : 1)
                }
            }

            ClassroomDivider()

            ClassroomFlow {
                ClassroomSecondaryButton(title: "Add class", symbol: "plus.circle") { store.addClass() }
            }

            Text(LocalizedStringKey("Add your own good and bad posture photos to build a dataset."))
                .font(.system(size: 10))
                .foregroundStyle(NotchDesign.Palette.eyebrow)
        }
    }

    private var tipsCard: some View {
        ClassroomCard {
            ClassroomCardTitle(text: "Tips for photographing sitting posture", trailing: AnyView(
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 11))
                    .foregroundStyle(NotchDesign.Palette.eyebrow)
            ))
            VStack(alignment: .leading, spacing: 8) {
                ClassroomInfoRow(symbol: "ruler", title: "Put the camera at chest height, 50–70 cm away, and keep the head-to-waist in frame.")
                ClassroomInfoRow(symbol: "sun.max", title: "Light the person from the front, avoid backlight, and turn filters off.")
                ClassroomInfoRow(symbol: "rotate.3d", title: "Shoot each posture from 3 angles: front, 45°, and side.")
                ClassroomInfoRow(symbol: "equal.circle", title: "Keep good and bad photos balanced so the model does not guess one side.")
                ClassroomInfoRow(symbol: "rectangle.dashed", title: "Use a clean background, a steady chair, and fill the frame with the person.")
            }
        }
    }

    private var checkCard: some View {
        ClassroomCard {
            ClassroomCardTitle(text: "Dataset check", trailing: AnyView(
                ClassroomStatusChip(
                    text: store.datasetReady ? "Dataset ready" : "Not built yet",
                    tint: store.datasetReady ? ClassroomStyle.good : NotchDesign.Palette.eyebrow
                )
            ))

            HStack(spacing: 8) {
                ClassroomStatTile(title: "Photos", value: "\(store.images.count)")
                ClassroomStatTile(title: "Annotated", value: "\(store.labeledCount)")
                ClassroomStatTile(title: "Classes", value: "\(store.classes.count)")
            }

            if store.images.isEmpty {
                ClassroomEmptyState(
                    title: "No photos yet",
                    message: "Use Add photos on the left to import your posture photos.",
                    symbol: "photo.on.rectangle.angled"
                )
                .frame(height: 110)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.adaptive(minimum: 46, maximum: 64), spacing: 6), count: 1), spacing: 6) {
                    ForEach(store.images) { image in
                        ClassroomThumbnail(image: image, classes: store.classes, library: store.libraryURL)
                    }
                }
            }

            ClassroomDivider()

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(LocalizedStringKey("Validation split"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(NotchDesign.Palette.text)
                    Spacer(minLength: 6)
                    Text("\(Int(store.splitRatio * 100))%")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(NotchDesign.Palette.text)
                        .monospacedDigit()
                }
                HStack(spacing: 5) {
                    ForEach([0.1, 0.2, 0.3], id: \.self) { ratio in
                        ClassroomChip(
                            title: "\(Int(ratio * 100))%",
                            selected: abs(store.splitRatio - ratio) < 0.001
                        ) {
                            store.splitRatio = ratio
                            store.datasetReady = false
                        }
                    }
                    Spacer(minLength: 0)
                }
                Text(LocalizedStringKey("Keep some photos as an exam the model never sees while training."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
            }

            ClassroomPrimaryButton(
                title: store.datasetReady ? "Dataset ready" : "Build a dataset",
                symbol: store.datasetReady ? "checkmark" : "square.stack.3d.up",
                enabled: store.stepOneReady
            ) {
                store.buildDataset()
            }

            if !store.datasetNote.isEmpty {
                Text(store.datasetNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(NotchDesign.Palette.secondaryText)
            } else if !store.stepOneReady {
                Text(LocalizedStringKey("You need at least two classes, each with photos."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(ClassroomStyle.warning)
            }
        }
    }

    private func importImages(className: Int) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.message = store.t("Choose photos for this class")
        if panel.runModal() == .OK {
            store.importImages(urls: panel.urls, className: className)
        }
    }
}

private struct ClassroomThumbnail: View {
    let image: ClassroomImage
    let classes: [ClassroomClass]
    let library: URL

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(NotchDesign.Palette.track)
            ClassroomPhoto(url: library.appendingPathComponent(image.fileName)) { nsImage in
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .frame(width: 46, height: 46)
            Circle()
                .fill(classes.indices.contains(image.className) ? classes[image.className].color : NotchDesign.Palette.eyebrow)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                .padding(3)
        }
        .frame(width: 46, height: 46)
        .overlay(alignment: .topLeading) {
            if image.isLabeled {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white, ClassroomStyle.good)
                    .padding(2)
            }
        }
    }
}

// MARK: - Step 2

struct ClassroomAnnotateStep: View {
    @ObservedObject var store: ClassroomStore

    var body: some View {
        ClassroomColumns(trailingWidth: 240) {
            VStack(spacing: 10) {
                canvasCard
                toolsRow
            }
            listCard.layoutValue(key: ClassroomColumn.self, value: 1)
        }
    }

    private var canvasCard: some View {
        ClassroomCard {
            ClassroomCardTitle(
                text: "Annotation tools",
                detail: "Drag on the photo to draw a box around the whole person (head to waist).",
                trailing: AnyView(
                    ClassroomStatusChip(
                        text: String(format: store.t("%d of %d done"), store.labeledCount, store.images.count),
                        tint: store.allLabeled ? ClassroomStyle.good : ClassroomStyle.accent
                    )
                )
            )

            if let image = store.annotatedImage {
                ClassroomPhoto(url: store.libraryURL.appendingPathComponent(image.fileName), maximumPixelSize: 1600) { nsImage in
                    ClassroomAnnotationCanvas(
                        image: nsImage,
                        boxes: image.boxes,
                        // The canvas only draws names, so hand it display names.
                        classes: store.classes.map { ClassroomClass(id: $0.id, name: store.displayName($0.name), hex: $0.hex) },
                        selectedClass: store.annotateClass
                    ) { rect, fittedSize in
                        store.addBox(rect, inViewSize: fittedSize, classIndex: store.annotateClass)
                    }
                }
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(NotchDesign.Palette.hairline, lineWidth: 1)
                }
            } else {
                ClassroomEmptyState(
                    title: "Go back to step 1 to add photos",
                    message: "Boxing needs photos first.",
                    symbol: "photo"
                )
                .frame(height: 320)
            }

            ClassroomFlow {
                ForEach(Array(store.classes.enumerated()), id: \.element.id) { index, item in
                    Button {
                        store.annotateClass = index
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(item.color).frame(width: 6, height: 6)
                            Text(store.displayName(item.name))
                                .font(.system(size: 10.5, weight: store.annotateClass == index ? .semibold : .regular))
                                .foregroundStyle(store.annotateClass == index ? Color.white : NotchDesign.Palette.text)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(
                            store.annotateClass == index ? NotchDesign.Palette.selected : NotchDesign.Palette.track,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
                ClassroomSecondaryButton(title: "Let the built-in model box it", symbol: "wand.and.stars") {
                    store.autoLabelCurrent()
                }
            }
        }
    }

    private var toolsRow: some View {
        ClassroomFlow {
            ClassroomSecondaryButton(title: "Previous photo", symbol: "chevron.left", enabled: store.annotateIndex > 0) {
                store.selectImage(store.annotateIndex - 1)
            }
            ClassroomSecondaryButton(title: "Next photo", symbol: "chevron.right", enabled: store.annotateIndex < store.images.count - 1) {
                store.selectImage(store.annotateIndex + 1)
            }
            ClassroomSecondaryButton(title: "Delete last box", symbol: "arrow.uturn.backward", enabled: !(store.annotatedImage?.boxes.isEmpty ?? true)) {
                store.removeLastBox()
            }
            ClassroomSecondaryButton(title: "Clear boxes", symbol: "trash", enabled: !(store.annotatedImage?.boxes.isEmpty ?? true)) {
                store.clearBoxes()
            }
            if let image = store.annotatedImage {
                Text(LocalizedStringKey(image.isLabeled ? "This photo is done" : "Nothing boxed here yet"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(image.isLabeled ? ClassroomStyle.good : ClassroomStyle.warning)
            }
        }
    }

    private var listCard: some View {
        ClassroomCard {
            ClassroomCardTitle(text: "Photo list", detail: "Boxed photos get a tick; unboxed ones do not count.")
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(store.images.enumerated()), id: \.element.id) { index, image in
                        Button {
                            store.selectImage(index)
                        } label: {
                            HStack(spacing: 7) {
                                ClassroomPhoto(url: store.libraryURL.appendingPathComponent(image.fileName)) { nsImage in
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 28, height: 28)
                                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                }
                                .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(store.classes.indices.contains(image.className) ? store.displayName(store.classes[image.className].name) : "—")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(NotchDesign.Palette.text)
                                        .lineLimit(1)
                                    Text(store.boxCount(image.boxes.count))
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(NotchDesign.Palette.secondaryText)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: image.isLabeled ? "checkmark.circle.fill" : "circle.dashed")
                                    .font(.system(size: 10))
                                    .foregroundStyle(image.isLabeled ? ClassroomStyle.good : NotchDesign.Palette.eyebrow)
                            }
                            .padding(5)
                            .background(
                                store.annotateIndex == index ? NotchDesign.Palette.track : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 300)
        }
    }
}

private struct ClassroomAnnotationCanvas: View {
    let image: NSImage
    let boxes: [ClassroomBox]
    let classes: [ClassroomClass]
    let selectedClass: Int
    let onBox: (CGRect, CGSize) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    private func fitted(in size: CGSize) -> CGRect {
        guard image.size.width > 0, image.size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func dragRect(_ fitted: CGRect) -> CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        ).intersection(fitted)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let frame = fitted(in: size)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.03)

                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)

                ForEach(boxes) { box in
                    let rect = CGRect(
                        x: frame.minX + box.x * frame.width,
                        y: frame.minY + box.y * frame.height,
                        width: box.width * frame.width,
                        height: box.height * frame.height
                    )
                    let color = classes.indices.contains(box.classIndex)
                        ? classes[box.classIndex].color
                        : ClassroomStyle.accent
                    Rectangle()
                        .strokeBorder(color, lineWidth: 2)
                        .background(color.opacity(0.10))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .overlay(alignment: .topLeading) {
                            Text(classes.indices.contains(box.classIndex) ? classes[box.classIndex].name : "")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(color, in: RoundedRectangle(cornerRadius: 3))
                                .offset(x: rect.minX, y: max(rect.minY - 14, 0))
                        }
                }

                if let rect = dragRect(frame) {
                    Rectangle()
                        .strokeBorder(ClassroomStyle.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .background(ClassroomStyle.accent.opacity(0.08))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        dragStart = value.startLocation
                        dragCurrent = value.location
                    }
                    .onEnded { value in
                        defer {
                            dragStart = nil
                            dragCurrent = nil
                        }
                        guard let start = dragStart else { return }
                        let rect = CGRect(
                            x: min(start.x, value.location.x),
                            y: min(start.y, value.location.y),
                            width: abs(value.location.x - start.x),
                            height: abs(value.location.y - start.y)
                        ).intersection(frame)
                        guard rect.width > 10, rect.height > 10 else { return }
                        onBox(
                            CGRect(
                                x: rect.minX - frame.minX,
                                y: rect.minY - frame.minY,
                                width: rect.width,
                                height: rect.height
                            ),
                            frame.size
                        )
                    }
            )
        }
    }
}
