import SwiftUI
import AppKit

struct CommandPaletteLayoutMetrics {
    static let `default` = Self()

    let searchFieldHeight: CGFloat = 50
    let searchFieldFontSize: CGFloat = 16
    let searchFieldCornerRadius: CGFloat = 14
    let searchFieldTopPadding: CGFloat = 20
    let searchFieldBottomPadding: CGFloat = 16
    let sectionSpacing: CGFloat = 14
    let rowVerticalPadding: CGFloat = 14
    let footerVerticalPadding: CGFloat = 14
    let resultsBottomPadding: CGFloat = 10
    let previewCardPadding: CGFloat = 14
}

struct CommandPaletteView: View {
    @EnvironmentObject private var palette: CommandPaletteViewModel
    private let metrics = CommandPaletteLayoutMetrics.default

    var body: some View {
        if palette.isPresented {
            ZStack {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
                    .onTapGesture {
                        palette.dismiss()
                    }

                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                        CommandPaletteSearchInput(
                            palette: palette,
                            metrics: metrics
                        )

                        if let sectionLabel {
                            Text(sectionLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        if let preview = palette.addWordPreview {
                            CommandPaletteAddWordPreviewCard(
                                preview: preview,
                                metrics: metrics,
                                onAdd: { palette.addCurrentQueryIfPossible() }
                            )
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, metrics.searchFieldTopPadding)
                    .padding(.bottom, metrics.searchFieldBottomPadding)

                    Divider()

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(palette.groupedItems, id: \.0) { section, items in
                                if !items.isEmpty {
                                    Text(section.rawValue)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 18)
                                        .padding(.top, metrics.sectionSpacing)
                                        .padding(.bottom, 8)

                                    ForEach(Array(items.enumerated()), id: \.element.id) { _, item in
                                        CommandPaletteRow(
                                            item: item,
                                            isHighlighted: palette.highlightedItemID == item.id,
                                            metrics: metrics,
                                            onSelect: { palette.execute(item) },
                                            onHover: { palette.highlightItem(id: item.id) }
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.bottom, metrics.resultsBottomPadding)
                    }
                    .frame(maxHeight: 340)

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text(palette.footerHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, metrics.footerVerticalPadding)
                }
                .frame(width: 620)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.14), radius: 24, y: 12)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .onAppear {
                    takeInputFocus()
                }
                .onChange(of: palette.isPresented) { isPresented in
                    if isPresented {
                        takeInputFocus()
                    }
                }
            }
        }
    }

    private var sectionLabel: String? {
        switch palette.mode {
        case .words:
            return palette.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Quick Access" : "Matching Results"
        case .commands:
            return nil
        case .collections:
            return nil
        }
    }

    private func takeInputFocus() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow else { return }
            if let searchField = window.contentView?.firstSubview(ofType: CommandPaletteSearchFieldView.self) {
                window.makeFirstResponder(searchField)
            } else {
                window.makeFirstResponder(nil)
            }
        }
    }
}

private struct CommandPaletteSearchInput: View {
    @ObservedObject var palette: CommandPaletteViewModel
    let metrics: CommandPaletteLayoutMetrics

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            CommandPaletteSearchField(
                text: Binding(
                    get: { palette.query },
                    set: { palette.updateQuery($0) }
                ),
                placeholder: palette.placeholder,
                fontSize: metrics.searchFieldFontSize,
                onMoveUp: { palette.moveSelection(delta: -1) },
                onMoveDown: { palette.moveSelection(delta: 1) },
                onSubmit: { palette.activateHighlightedItem() },
                onCommandSubmit: { palette.addCurrentQueryIfPossible() },
                onEscape: { palette.dismiss() }
            )
            .frame(minHeight: 24, idealHeight: 24, maxHeight: 24)

            if !palette.query.isEmpty {
                Button {
                    palette.updateQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: metrics.searchFieldHeight, idealHeight: metrics.searchFieldHeight, maxHeight: metrics.searchFieldHeight)
        .background(
            RoundedRectangle(cornerRadius: metrics.searchFieldCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.searchFieldCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .background {
            Button("Add Current Query") {
                palette.addCurrentQueryIfPossible()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!palette.canAddCurrentQuery)
            .hidden()
        }
    }
}

private struct CommandPaletteAddWordPreviewCard: View {
    let preview: CommandPaletteAddWordPreview
    let metrics: CommandPaletteLayoutMetrics
    let onAdd: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    if let canonicalWord = preview.canonicalWord,
                       canonicalWord.caseInsensitiveCompare(preview.query) != .orderedSame {
                        Text(canonicalWord)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                }

                if let definition = preview.definition, !definition.isEmpty {
                    Text(definition)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(preview.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if preview.isAddable {
                Button("Add") {
                    onAdd()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(metrics.previewCardPadding)
        .background(backgroundShape)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var title: String {
        switch preview.status {
        case .checking:
            return "Checking \"\(preview.query)\""
        case .readyToAdd:
            return "Add \"\(preview.query)\""
        case .duplicateExistingWord:
            return "\"\(preview.query)\" already exists"
        case .notFound:
            return "No dictionary match for \"\(preview.query)\""
        case .failed:
            return "Lookup failed for \"\(preview.query)\""
        }
    }

    private var iconName: String {
        switch preview.status {
        case .checking:
            return "clock.arrow.circlepath"
        case .readyToAdd:
            return "plus.circle.fill"
        case .duplicateExistingWord:
            return "checkmark.circle.fill"
        case .notFound:
            return "questionmark.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch preview.status {
        case .checking:
            return .secondary
        case .readyToAdd:
            return .accentColor
        case .duplicateExistingWord:
            return .green
        case .notFound:
            return .secondary
        case .failed:
            return .orange
        }
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(backgroundColor)
    }

    private var backgroundColor: Color {
        switch preview.status {
        case .checking:
            return Color.primary.opacity(0.04)
        case .readyToAdd:
            return Color.accentColor.opacity(0.10)
        case .duplicateExistingWord:
            return Color.green.opacity(0.10)
        case .notFound:
            return Color.primary.opacity(0.035)
        case .failed:
            return Color.orange.opacity(0.10)
        }
    }

    private var borderColor: Color {
        switch preview.status {
        case .checking:
            return Color.primary.opacity(0.08)
        case .readyToAdd:
            return Color.accentColor.opacity(0.25)
        case .duplicateExistingWord:
            return Color.green.opacity(0.25)
        case .notFound:
            return Color.primary.opacity(0.08)
        case .failed:
            return Color.orange.opacity(0.25)
        }
    }
}

private struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let isHighlighted: Bool
    let metrics: CommandPaletteLayoutMetrics
    let onSelect: () -> Void
    let onHover: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(item.isSelectable ? Color.accentColor : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if let trailingText = item.trailingText {
                Text(trailingText)
                    .font(.caption.weight(.medium))
                    .foregroundColor(isHighlighted ? Color.primary.opacity(0.82) : .secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, metrics.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundShape)
        .overlay(overlayShape)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            guard hovering else { return }
            onHover()
        }
        .id("\(item.id)-\(isHighlighted ? "highlighted" : "normal")")
    }

    @ViewBuilder
    private var backgroundShape: some View {
        if isHighlighted && item.isSelectable {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var overlayShape: some View {
        if isHighlighted && item.isSelectable {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
        } else {
            Color.clear
        }
    }
}

private struct CommandPaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let fontSize: CGFloat
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onSubmit: () -> Void
    let onCommandSubmit: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> CommandPaletteSearchFieldView {
        let searchField = CommandPaletteSearchFieldView()
        searchField.delegate = context.coordinator
        context.coordinator.attach(field: searchField)
        searchField.commandHandler = { command in
            switch command {
            case .moveUp:
                onMoveUp()
            case .moveDown:
                onMoveDown()
            case .submit:
                onSubmit()
            case .commandSubmit:
                onCommandSubmit()
            case .escape:
                onEscape()
            }
        }
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: fontSize, weight: .medium)
        searchField.lineBreakMode = .byTruncatingTail
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.wraps = false
        searchField.placeholderString = placeholder
        searchField.stringValue = text
        return searchField
    }

    func updateNSView(_ nsView: CommandPaletteSearchFieldView, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate, NSControlTextEditingDelegate {
        @Binding private var text: String
        private weak var field: CommandPaletteSearchFieldView?

        init(text: Binding<String>) {
            _text = text
        }

        func attach(field: CommandPaletteSearchFieldView) {
            self.field = field
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let field else { return false }
            return field.handleCommand(selector: commandSelector, currentEvent: NSApp.currentEvent)
        }
    }
}

private final class CommandPaletteSearchFieldView: NSTextField {
    enum Command {
        case moveUp
        case moveDown
        case submit
        case commandSubmit
        case escape
    }

    var commandHandler: ((Command) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        isEditable = true
        isSelectable = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        isEditable = true
        isSelectable = true
    }

    @discardableResult
    func handleCommand(selector: Selector, currentEvent: NSEvent?) -> Bool {
        switch selector {
        case #selector(moveUp(_:)):
            commandHandler?(.moveUp)
            return true
        case #selector(moveDown(_:)):
            commandHandler?(.moveDown)
            return true
        case #selector(cancelOperation(_:)):
            commandHandler?(.escape)
            return true
        case #selector(insertNewline(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)):
            if currentEvent?.modifierFlags.contains(.command) == true {
                commandHandler?(.commandSubmit)
            } else {
                commandHandler?(.submit)
            }
            return true
        default:
            return false
        }
    }

    override func doCommand(by selector: Selector) {
        if handleCommand(selector: selector, currentEvent: NSApp.currentEvent) {
            return
        }
        super.doCommand(by: selector)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 36 {
            commandHandler?(.commandSubmit)
            return
        }
        switch event.keyCode {
        case 125:
            if handleCommand(selector: #selector(moveDown(_:)), currentEvent: event) { return }
        case 126:
            if handleCommand(selector: #selector(moveUp(_:)), currentEvent: event) { return }
        case 53:
            if handleCommand(selector: #selector(cancelOperation(_:)), currentEvent: event) { return }
        case 36, 76:
            if handleCommand(selector: #selector(insertNewline(_:)), currentEvent: event) { return }
        default:
            break
        }
        super.keyDown(with: event)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 24)
    }
}

private extension NSView {
    func firstSubview<T: NSView>(ofType type: T.Type) -> T? {
        if let selfAsType = self as? T {
            return selfAsType
        }
        for subview in subviews {
            if let match = subview.firstSubview(ofType: type) {
                return match
            }
        }
        return nil
    }
}
