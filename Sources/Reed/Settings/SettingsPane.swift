import SwiftUI

/// The scaffold every Settings tab renders into: title, hint, scrollable
/// content, and an optional bottom bar pinned
/// below the scroll view. Split out of SettingsComponents.swift for the
/// swiftlint file-length cap (same pattern as the other Settings files).
struct SettingsPane<Content: View>: View {
    let title: String
    var hint: String?
    /// Rendered OUTSIDE the scroll view, pinned to the pane's bottom edge —
    /// for page-end signatures like About's copyright, which should sit at
    /// the bottom regardless of content height or scroll position.
    var bottomBar: AnyView?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsSpace.xl) {
                    VStack(alignment: .leading, spacing: SettingsSpace.xs) {
                        Text(title).font(SettingsType.title)
                        if let hint {
                            Text(hint).font(SettingsType.hint).foregroundStyle(.secondary)
                        }
                    }
                    content()
                }
                .padding(.horizontal, SettingsSpace.xxl)
                .padding(.vertical, SettingsSpace.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            if let bottomBar {
                bottomBar
                    .padding(.horizontal, SettingsSpace.xxl)
                    .padding(.bottom, SettingsSpace.lg)
            }
        }
    }
}
