import SwiftUI
import AppKit

struct CommandPaletteView: View {
    @EnvironmentObject private var palette: CommandPaletteViewModel

    var body: some View {
        if palette.isPresented {
            ZStack {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
                    .onTapGesture {
                        palette.dismiss()
                    }

                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        CommandPaletteSearchField(
                            text: Binding(
                                get: { palette.query },
                                set: { palette.updateQuery($0) }
                            ),
                            placeholder: palette.placeholder,
                            onMoveUp: { palette.moveSelection(delta: -1) },
                            onMoveDown: { palette.moveSelection(delta: 1) },
                            onSubmit: { palette.activateHighlightedItem() },
                            onCommandSubmit: { palette.addCurrentQueryIfPossible() },
                            onEscape: { palette.dismiss() }
                        )
                        .frame(height: 42)

                        if let sectionLabel {
                            Text(sectionLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        if palette.canAddCurrentQuery {
                            Label("Press Cmd+Enter to add the current query directly", systemImage: "return")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                    Divider()

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(palette.groupedItems, id: \.0) { section, items in
                                if !items.isEmpty {
                                    Text(section.rawValue)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 18)
                                        .padding(.top, 14)
                                        .padding(.bottom, 8)

                                    ForEach(Array(items.enumerated()), id: \.element.id) { _, item in
                                        CommandPaletteRow(
                                            item: item,
                                            isHighlighted: palette.highlightedItemID == item.id,
                                            onSelect: { palette.execute(item) },
                                            onHover: { palette.highlightItem(id: item.id) }
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 8)
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
                    .padding(.vertical, 12)
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
                .background {
                    Button("Add Current Query") {
                        palette.addCurrentQueryIfPossible()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!palette.canAddCurrentQuery)
                    .hidden()
                }
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

private struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let isHighlighted: Bool
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
        .padding(.vertical, 12)
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
        searchField.sendsSearchStringImmediately = true
        searchField.recentsAutosaveName = nil
        searchField.maximumRecents = 0
        searchField.focusRingType = .none
        searchField.bezelStyle = .roundedBezel
        searchField.font = .systemFont(ofSize: 18, weight: .semibold)
        searchField.lineBreakMode = .byTruncatingTail
        searchField.cell?.wraps = false
        searchField.cell?.usesSingleLineMode = true
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

    final class Coordinator: NSObject, NSSearchFieldDelegate, NSControlTextEditingDelegate {
        @Binding private var text: String
        private weak var field: CommandPaletteSearchFieldView?

        init(text: Binding<String>) {
            _text = text
        }

        func attach(field: CommandPaletteSearchFieldView) {
            self.field = field
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let field else { return false }
            return field.handleCommand(selector: commandSelector, currentEvent: NSApp.currentEvent)
        }
    }
}

private final class CommandPaletteSearchFieldView: NSSearchField {
    enum Command {
        case moveUp
        case moveDown
        case submit
        case commandSubmit
        case escape
    }

    var commandHandler: ((Command) -> Void)?

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
