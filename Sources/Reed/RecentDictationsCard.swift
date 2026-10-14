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
                    metaLabel(newest, now: now)
                    Spacer()
                    copyButton(newest)
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
    }

    private func earlierRow(_ entry: RecentDictation, now: Date) -> some View {
        let copied = copiedID == entry.id
        return Button { copy(entry) } label: {
            HStack(spacing: 10) {
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
    }

    /// The age and target app, at its natural width: `label` already
    /// shortens a long app name, so the preview keeps the rest of the row.
    private func metaLabel(_ entry: RecentDictation, now: Date) -> some View {
        Text(RecentDictations.label(entry, now: now))
            .font(ReedFont.ui(11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
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
