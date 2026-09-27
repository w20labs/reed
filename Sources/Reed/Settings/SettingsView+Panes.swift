import AppKit
import KeyboardShortcuts
import SwiftUI

/// The marketing/legal destinations Settings links out to. Named constants so
/// the URLs live in one place rather than inline in copy.
///
/// Reed's home is reed.w20.ai (founder decision 2026-08-06 — w20labs.ai is
/// owned but unconfigured, no DNS/MX; it once resolved to the user's router).
/// The legal pages ship with the launch site deploy at these exact paths.
enum ReedLinks {
    static let site = "https://reed.w20.ai"
    static let privacy = "https://reed.w20.ai/legal/privacy.html"
    /// The standalone "what we collect" page — separate from the Termageddon-
    /// embedded privacy policy so it can be edited without touching that file.
    static let privacyWhatWeCollect = "https://reed.w20.ai/legal/what-we-collect.html"
}

/// `Text(LocalizedStringKey("[label](\(url))"))` looks like it substitutes `url`
/// into the link's target, but it doesn't: `LocalizedStringKey` interpolation
/// replaces the value with a `%@` format placeholder for its localization-table
/// lookup, and that placeholder — not the URL — is what ends up as the parsed
/// link's target. Clicking it then hands NSWorkspace the literal string "%@",
/// which fails with paramErr (-50) instead of opening anything. Building the
/// `AttributedString` from a plain (non-`LocalizedStringKey`) `String` avoids
/// that interpolation path and substitutes correctly.
func markdownText(_ raw: String) -> Text {
    guard var attributed = try? AttributedString(
        markdown: raw,
        options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    ) else { return Text(raw) }
    // Links used to be told apart by being green. Green is a shape colour now
    // (2.76:1 as text), so every markdown link is underlined here instead —
    // at the helper, so no call site can demote a link's colour and leave it
    // indistinguishable from the sentence around it. Callers still set the
    // colour with `.tint`.
    for run in attributed.runs where run.link != nil {
        attributed[run.range].underlineStyle = .single
    }
    return Text(attributed)
}

/// The right-hand content panes for each sidebar tab. Split out so
/// SettingsView.swift stays under swiftlint's type_body_length / file_length.
extension SettingsView {
    @ViewBuilder
    var paneContent: some View {
        switch selected {
        case .dictation:    dictationPane
        case .cleanup:      cleanupPane
        case .permissions:  permissionsPane
        case .privacy:      privacyPane
        case .about:        aboutPane
        }
    }

    // MARK: - Dictation

    var dictationPane: some View {
        // Cleanup has its own tab; this pane is only how a dictation starts.
        SettingsPane(title: "Dictation", hint: "How you start a dictation.") {
            CardGroup {
                VStack(alignment: .leading, spacing: SettingsSpace.sm) {
                    PaneRow(icon: "keyboard", title: "Push-to-talk",
                            subtitle: "Hold to record, release to transcribe.") {
                        PushToTalkField()
                    }
                    Text("Press ⌃, ⌥, or ⌘ with a key - like ⌃⌥R. Or press ⌃⌥, ⌃⌘, or ⌥⌘.")
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        // Aligns under the row's title: PaneRow's own leading
                        // padding, plus the icon's width, plus its icon-to-
                        // title spacing.
                        .padding(.leading, SettingsSpace.lg + 24 + SettingsSpace.md)
                        .padding(.trailing, SettingsSpace.lg)
                        // Matches PaneRow's own bottom inset so this note
                        // doesn't sit flush against the divider.
                        .padding(.bottom, SettingsSpace.md)
                }
                CardDivider()
                MicrophoneRow(coordinator: coordinator)
            }
        }
    }

    // MARK: - Permissions

    var permissionsPane: some View {
        SettingsPane(title: "Permissions",
                     hint: "Reed needs these to hear you and paste your words.") {
            CardGroup {
                permissionRow(
                    label: "Microphone", icon: "mic.fill", granted: micGranted,
                    helpText: "Required to capture audio.",
                    openURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                )
                CardDivider()
                permissionRow(
                    label: "Accessibility", icon: "accessibility", granted: axGranted,
                    helpText: "Required to paste text into other apps.",
                    openURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
            }
        }
    }

    @ViewBuilder
    func permissionRow(
        label: String, icon: String, granted: Bool, helpText: String, openURL: String
    ) -> some View {
        PaneRow(icon: icon, title: label, subtitle: helpText) {
            HStack(spacing: SettingsSpace.sm) {
                StatusPill(granted: granted)
                Button(granted ? "Manage" : "Grant") {
                    if let url = URL(string: openURL) { NSWorkspace.shared.open(url) }
                }
                // The design's `.sbtn` (white, hairline, 8-pt radius) — the
                // bare .controlSize(.small) default rendered the macOS gray
                // bezel instead of the mock (same drift class as the
                // onboarding capsule fix).
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    // MARK: - Privacy

    var privacyPane: some View {
        SettingsPane(title: "Privacy", hint: "No usage analytics, no crash reports.") {
            // The promise, where users look for it (P15, DECIDED 2026-09-02).
            // A statement, not a control: there is no other place dictation
            // can run.
            CardGroup(label: "On this Mac") {
                PaneRow(icon: "mic",
                        title: "Dictation runs on your Mac.",
                        subtitle: "Nothing leaves it - not your voice, not your text.") { EmptyView() }
            }
            // No telemetry since 2026-09-26: no analytics and no crash
            // reports, so there is nothing to switch on or off. The two
            // connections that remain are named rather than hidden.
            CardGroup(
                label: "Connections",
                footer: LocalizedStringKey(
                    "[See exactly what Reed connects to](\(ReedLinks.privacyWhatWeCollect))"
                )
            ) {
                PaneRow(icon: "hand.raised",
                        title: "Two connections, nothing else.",
                        subtitle: "Downloading the speech model and checking for updates. Like any web request, they carry your IP address; the update check also names the app version.") { EmptyView() }
            }
        }
    }

    // MARK: - About

    var aboutPane: some View {
        // Copyright is a page-end signature — pinned to the pane's bottom
        // edge via bottomBar (founder review 2026-08-05: it floated mid-pane
        // whenever the content was short).
        SettingsPane(title: "About",
                     hint: "The version you're running, and where to report a problem.",
                     bottomBar: AnyView(
            // "W20 Labs Inc." — no comma; matches the certificate of
            // incorporation exactly.
            markdownText("© 2026 [W20 Labs Inc.](\(ReedLinks.site))")
                .font(SettingsType.footnote)
                .foregroundStyle(.tertiary)
                .tint(.primary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        )) {
            // Identity without chrome (P10): the lockup is a brand statement,
            // not a settings group — no card around it. Version+build merge
            // into one click-to-copy mono line (support asks for exactly that
            // string); the Version/Build icon-row card is gone.
            VStack(spacing: SettingsSpace.xs) {
                ReedAppIcon()
                    .frame(width: 52, height: 52)
                Text("Reed")
                    .font(ReedFont.ui(17, 600))
                    .padding(.top, SettingsSpace.sm)
                Text("Hold to talk. Release for clean text.")
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(.secondary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(appVersion) (\(buildNumber))", forType: .string)
                } label: {
                    Text("\(appVersion) (\(buildNumber))")
                        .font(SettingsType.mono)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Click to copy")
                .padding(.top, SettingsSpace.xs)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, SettingsSpace.lg)

            // Reed has no server of its own: reports go to the repository's
            // bug form, where the user decides what to paste.
            CardGroup {
                PaneRow(icon: "exclamationmark.bubble", title: "Report an issue",
                        subtitle: "Opens the bug report form on GitHub.") {
                    Button("Report") { coordinator.openReportIssue() }
                        .controlSize(.regular)
                }
                CardDivider()
                // The notices build-app.sh packages, readable offline. Reed
                // shipped them from 0.2.5 but gave nobody a way to read them.
                PaneRow(icon: "doc.text", title: "Acknowledgements",
                        subtitle: "Licences for the software Reed includes.") {
                    Button("Open") { showingAcknowledgements = true }
                        .controlSize(.regular)
                }
            }

        }
        .sheet(isPresented: $showingAcknowledgements) {
            AcknowledgementsView { showingAcknowledgements = false }
        }
    }

}

// MARK: - Push-to-talk field

/// The push-to-talk control — the onboarding recorder, reused: one click-to-arm
/// field that captures both bare-modifier holds and full combos. No preset
/// menu; `HotkeyRecorderField` owns the capture and the `PushToTalkTrigger`
/// storage, so Settings and onboarding can't drift.
private struct PushToTalkField: View {
    @State private var custom = KeyboardShortcuts.getShortcut(for: .toggleDictation)

    var body: some View {
        HotkeyRecorderField(layout: .row, custom: $custom)
    }
}
