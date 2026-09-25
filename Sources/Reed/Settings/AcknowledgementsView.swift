import AppKit
import SwiftUI

/// An offline reader for the notices Reed packages (design →
/// "Settings › About · Acknowledgements"). Titles on the left, the selected
/// text on the right, verbatim: no Markdown, no links followed, no network.
/// The texts are whatever `build-app.sh` put in the bundle — this view never
/// carries licence text of its own.
struct AcknowledgementsView: View {
    var store = AcknowledgementsStore()
    var onClose: () -> Void = {}

    @State private var entries: [Acknowledgement] = []
    @State private var problems: [AcknowledgementProblem] = []
    @State private var selectedID: Acknowledgement.ID?
    /// The body of the current selection, or why it could not be read. Reset
    /// on every selection change so a failure never shows the previous notice.
    @State private var shown: Result<String, AcknowledgementProblem>?

    var body: some View {
        VStack(spacing: 0) {
            Text("Acknowledgements")
                .font(SettingsType.title)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SettingsSpace.md)
            Divider()
            if entries.isEmpty {
                unavailable
            } else {
                content
            }
            Divider()
            HStack {
                if !entries.isEmpty, let warning = problems.first {
                    Text(warning.message)
                        .font(SettingsType.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: SettingsSpace.sm)
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(SettingsSpace.md)
        }
        .frame(width: 720, height: 520)
        .onAppear(perform: load)
    }

    private var content: some View {
        HSplitView {
            List(entries, selection: $selectedID) { entry in
                Text(entry.title)
                    .font(SettingsType.rowSubtitle)
                    .accessibilityLabel(entry.title)
                    .tag(entry.id)
            }
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 300)
            switch shown {
            case .success(let text):
                NoticeText(text: text)
                    .accessibilityLabel("Notice text")
            case .failure(let problem):
                message(problem.message)
            case nil:
                message("Select a notice to read it.")
            }
        }
        .onChange(of: selectedID) { _, _ in loadSelection() }
    }

    private var unavailable: some View {
        VStack(spacing: SettingsSpace.sm) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Acknowledgements are unavailable")
                .font(SettingsType.rowTitle)
            ForEach(problems.indices, id: \.self) { index in
                Text(problems[index].message)
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(SettingsSpace.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(SettingsType.rowSubtitle)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(SettingsSpace.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
        let result = store.inventory()
        entries = result.entries
        problems = result.problems
        if selectedID == nil { selectedID = entries.first?.id }
        loadSelection()
    }

    private func loadSelection() {
        guard let id = selectedID, let entry = entries.first(where: { $0.id == id }) else {
            shown = nil
            return
        }
        shown = store.text(for: entry)
    }
}

/// A read-only `NSTextView`: native selection, keyboard scrolling and word
/// wrap. SwiftUI's `Text` lays out its whole string eagerly, which stalls on
/// the 6,000-line ONNX Runtime notice; `NSTextView` pages it.
private struct NoticeText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textContainerInset = NSSize(width: SettingsSpace.md, height: SettingsSpace.md)
        // Wrap rather than scroll sideways: a licence with long lines stays
        // readable without a horizontal scrollbar.
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("Notice text")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        // Back to the top: the previous notice's scroll position means
        // nothing in a different document.
        view.scroll(.zero)
    }
}
