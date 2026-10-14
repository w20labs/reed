import AppKit
import SwiftUI

/// The menu's recent dictations (P18, decided 2026-10-14): the newest as a
/// three-line preview with Copy, the ones before it as single-line rows that
/// copy on click. Every Copy takes the complete text. Labelled LAST DICTATION
/// until a second dictation exists, then RECENT.
struct RecentDictationsCard: View {
    let dictations: RecentDictations
    let onClear: () -> Void
    var rowWidthForTesting: ((CGFloat) -> Void)?
    var copyReadyForTesting: ((RecentDictationsCard) -> Void)?
    var copyButtonWidthForTesting: ((CGFloat) -> Void)?
    /// The entry whose Copy just fired: it shows "Copied" for 1.6 s.
    @State var copiedID: UUID?
    /// Which Copy is the latest: a timer clears the feedback only if no later
    /// Copy (of any entry, or the same one again) has fired since its own.
    @State private var copyGeneration = 0
    @State private var hoveredID: UUID?

    var body: some View {
        if let newest = dictations.newest {
            // Ages are re-read every 30 s while the menu is open.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                card(newest: newest, now: context.date)
                    .onAppear { copyReadyForTesting?(self) }
            }
        }
    }

    private func card(newest: RecentDictation, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(dictations.earlier.isEmpty ? "LAST DICTATION" : "RECENT")
                    .font(ReedFont.ui(10, 600))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                Spacer()
                Button(action: onClear) {
                    Text("Clear")
                        .font(ReedFont.ui(11, 500))
                        .underline()
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear this list")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    // Copy keeps its full width; the label truncates instead.
                    metaLabel(newest, now: now)
                    Spacer(minLength: 8)
                    copyButton(newest)
                        .fixedSize()
                }
                Text(newest.text)
                    .font(ReedFont.ui(12))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }

            if !dictations.earlier.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(dictations.earlier) { entry in
                        earlierRow(entry, now: now)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        }
    }

    private func copyButton(_ entry: RecentDictation) -> some View {
        let copied = copiedID == entry.id
        return Button { copy(entry) } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                Text(copied ? "Copied" : "Copy")
                    .font(ReedFont.ui(11, 500))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(hoveredID == entry.id ? 0.7 : 0))
            }
        }
        .buttonStyle(.plain)
        .onHover { hoveredID = $0 ? entry.id : nil }
        .help("Copy the transcript - handy if it didn't paste at your cursor")
        .background(GeometryReader { proxy in
            Color.clear.onAppear { copyButtonWidthForTesting?(proxy.size.width) }
        })
    }

    private func earlierRow(_ entry: RecentDictation, now: Date) -> some View {
        let copied = copiedID == entry.id
        return Button { copy(entry) } label: {
            PreviewThenLabel(minPreview: Self.minPreviewWidth, spacing: 10) {
                Text(entry.text)
                    .font(ReedFont.ui(12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { proxy in
                        Color.clear.onAppear { rowWidthForTesting?(proxy.size.width) }
                    })
                if copied {
                    Label("Copied", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .font(ReedFont.ui(11, 500))
                        .foregroundStyle(.secondary)
                } else {
                    metaLabel(entry, now: now)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(copied || hoveredID == entry.id ? 0.7 : 0))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .onHover { hoveredID = $0 ? entry.id : nil }
        .help("Copy this dictation")
        .accessibilityLabel("\(entry.text), \(RecentDictations.label(entry, now: now))")
    }

    /// An earlier row's preview never gets less than this, whatever the
    /// app's name is made of (review 2026-10-14: 16 CJK characters left it
    /// 1.5 pt; a character limit does not bound rendered width).
    static let minPreviewWidth: CGFloat = 110

    /// "4 min · Slack": the age always whole; the app name truncates to
    /// whatever width the row leaves it.
    private func metaLabel(_ entry: RecentDictation, now: Date) -> some View {
        HStack(spacing: 0) {
            Text(RecentDictations.age(of: entry.date, now: now))
                .fixedSize()
            if let app = entry.appName {
                Text(" · \(app)")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(ReedFont.ui(11))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    func copy(_ entry: RecentDictation) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        copiedID = entry.id
        copyGeneration += 1
        let generation = copyGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if copyGeneration == generation { copiedID = nil }
        }
    }
}

/// An earlier row: the preview (first subview) and the label (second). The
/// label gets its natural width, but never so much that the preview drops
/// below `minPreview`; the preview takes the rest. A short label leaves the
/// preview the whole row, a long one truncates instead of crowding it out.
private struct PreviewThenLabel: Layout {
    let minPreview: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = sizes.map(\.height).max() ?? 0
        let width = proposal.width ?? sizes.map(\.width).reduce(spacing, +)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let labelIdeal = subviews[1].sizeThatFits(.unspecified).width
        let labelWidth = min(labelIdeal, max(0, bounds.width - minPreview - spacing))
        let previewWidth = max(0, bounds.width - labelWidth - spacing)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: previewWidth, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                          proposal: ProposedViewSize(width: labelWidth, height: bounds.height))
    }
}
