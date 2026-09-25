import SwiftUI

/// Settings building blocks for the sidebar layout (design/hud-design-system.html
/// → Settings: charcoal rail, Reed-green spark). System font throughout, sentence-case pane
/// titles, and rows grouped into a single rounded card per group with soft
/// inset dividers — not one bordered box per row. Native controls (SecureField,
/// Toggle, KeyboardShortcuts.Recorder) live inside the rows, so security +
/// accessibility + hotkey capture are preserved.
///
/// Layout follows a strict 4-point grid: every spacing / padding / gap / size /
/// radius is a multiple of 4 (see `SettingsSpace`). The only exceptions are
/// 1px hairlines and border strokes (physical lines, not layout). Mirror any
/// change in the Figma tokens comment in design/hud-design-system.html.

/// The 4-point spacing scale — the single source for every gap and inset.
enum SettingsSpace {
    // ~10% larger than the base 4-pt grid, to make Settings roomier without
    // scaling or bigger fonts.
    static let xs: CGFloat = 4
    static let sm: CGFloat = 9
    static let md: CGFloat = 13
    static let lg: CGFloat = 18
    static let xl: CGFloat = 22
    static let xxl: CGFloat = 26
}

enum SettingsStyle {
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    /// Nested rows and bands inside a pane (quality rows, banners) — fixed
    /// radius per the design system, not on the spacing scale.
    static let nestedRadius: CGFloat = 10
    /// Micro-badges (RowTag) — fixed radius, not on the spacing scale.
    static let tagRadius: CGFloat = 6
    static var cardFill: Color { Color(nsColor: .textBackgroundColor) }
    static var inputFill: Color { Color(nsColor: .windowBackgroundColor) }
    static var hairline: Color { Color(nsColor: .separatorColor).opacity(0.6) }
    static var rowDivider: Color { Color(nsColor: .separatorColor).opacity(0.45) }
    /// Charcoal #26262A — the STRUCTURE accent: selected tab, toggles, primary
    /// buttons. The sidebar rail is this color. See the "charcoal
    /// structure + green spark" system in design/hud-design-system.html.
    static let charcoal = Color(red: 0.149, green: 0.149, blue: 0.165)
    /// Warm greige #FAF9F6 — the content-pane surface that cards sit on.
    static let pane = Color(red: 0.980, green: 0.976, blue: 0.965)
    /// #55AF48 — the logo's green, shared with the website and onboarding.
    /// A SHAPE colour only: brand dot, success checks, badges, progress.
    /// Never a large structural fill, and never a text colour — see
    /// `onGreen` for what goes on top of it.
    static let green = Color(red: 0.333, green: 0.686, blue: 0.282)
    /// Ink, for text and glyphs drawn on the green (6.10:1).
    static let onGreen = Color(red: 0.114, green: 0.114, blue: 0.122)
    static let amber = Color(red: 0.875, green: 0.541, blue: 0.118)  // #DF8A1E — design-system amber
    /// #D9483F — hard failures (the menu error banner).
    static let red = Color(red: 0.851, green: 0.282, blue: 0.247)
}

/// The one canonical Settings type scale — the macOS system font (SF Pro / SF
/// Mono, via ReedFont, which is the system font app-wide now). Keep in sync with
/// the Figma "Type" block in design/hud-design-system.html.
enum SettingsType {
    // +1px over the base scale for a slightly larger, more comfortable read.
    static let title = ReedFont.ui(19, 600)      // pane title
    static let hint = ReedFont.ui(13)            // pane subtitle
    static let groupLabel = ReedFont.ui(13, 600) // card group label
    static let rowTitle = ReedFont.ui(15)        // row title
    static let rowSubtitle = ReedFont.ui(13)     // row subtitle
    static let footnote = ReedFont.ui(13)        // footers, links
    static let email = ReedFont.ui(17, 600)      // account email
    static let sidebar = ReedFont.ui(15)         // sidebar item
    static let mono = ReedFont.mono(13)          // values / chips
    static let badge = ReedFont.mono(11, 700)    // plan badge / tag
}

/// One nav item on the charcoal rail. Selected = a subtle white overlay (charcoal
/// carries structure; green stays a spark only); unselected = light text on charcoal.
struct SidebarItem: View {
    let icon: String
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SettingsSpace.sm) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.6))
                    .frame(width: 20)
                Text(title)
                    .font(SettingsType.sidebar)
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.72))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsSpace.sm)
            .padding(.vertical, SettingsSpace.sm)
            .background(
                RoundedRectangle(cornerRadius: SettingsStyle.controlRadius, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A content pane: big sentence-case title, optional hint, then groups —
/// scrolls independently of the sidebar.
/// An optional small group label + a rounded card of rows + optional markdown
/// footer. The card provides the border/fill; rows inside are borderless.
struct CardGroup<Content: View>: View {
    var label: String?
    var footer: LocalizedStringKey?
    var dimmed: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpace.sm) {
            if let label {
                Text(label)
                    .font(SettingsType.groupLabel)
                    .foregroundStyle(.secondary)
                    .padding(.leading, SettingsSpace.xs)
            }
            VStack(spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous)
                        .fill(SettingsStyle.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous)
                        .strokeBorder(SettingsStyle.hairline, lineWidth: 1)
                )
                .opacity(dimmed ? 0.55 : 1)
            if let footer {
                Text(footer)
                    .font(SettingsType.footnote)
                    .foregroundStyle(.secondary)
                    .tint(.primary)
                    .frame(maxWidth: 500, alignment: .leading)
                    .padding(.top, SettingsSpace.xs)
            }
        }
    }
}

/// Inset hairline between rows within a card — aligned under the row text
/// (18 pad + 24 icon + 13 gap = 55).
struct CardDivider: View {
    var inset: CGFloat = 55
    var body: some View {
        Rectangle()
            .fill(SettingsStyle.rowDivider)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// A row inside a card: leading SF Symbol, title (+ optional subtitle),
/// trailing control. No border — the enclosing card draws it.
struct PaneRow<Trailing: View>: View {
    var icon: String?
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: SettingsSpace.md) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: SettingsSpace.xs) {
                Text(title).font(SettingsType.rowTitle)
                if let subtitle {
                    Text(subtitle).font(SettingsType.rowSubtitle).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: SettingsSpace.sm)
            trailing()
        }
        .padding(.horizontal, SettingsSpace.lg)
        .padding(.vertical, SettingsSpace.md)
    }
}

/// Small white bordered pill button — the design's secondary action (the
/// permission rows' Grant / Manage).
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ReedFont.ui(13, 500))
            .foregroundStyle(SettingsStyle.charcoal)
            .padding(.horizontal, SettingsSpace.md)
            .padding(.vertical, SettingsSpace.xs)
            .background(
                RoundedRectangle(cornerRadius: SettingsStyle.controlRadius, style: .continuous)
                    .fill(SettingsStyle.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsStyle.controlRadius, style: .continuous)
                    .strokeBorder(
                        configuration.isPressed ? SettingsStyle.charcoal.opacity(0.4) : SettingsStyle.hairline,
                        lineWidth: 1
                    )
            )
    }
}

extension View {
    /// The one charcoal action-link look: 13/500 charcoal with a soft
    /// underline. Underline is the affordance — charcoal text alone reads as
    /// a label, and green is reserved for navigation links (which stay green
    /// and un-underlined). Applies to Sign out, Choose a different plan,
    /// Check now, Change.
    func settingsActionLink() -> some View {
        font(ReedFont.ui(13, 500))
            .foregroundStyle(SettingsStyle.charcoal)
            .underline(true, color: SettingsStyle.charcoal.opacity(0.35))
    }

    /// The one text-field look for Settings: white fill + hairline border on
    /// the control radius — a live control is never grey at rest.
    func settingsFieldBox() -> some View {
        padding(.horizontal, SettingsSpace.md)
            .padding(.vertical, SettingsSpace.sm)
            .background(
                RoundedRectangle(cornerRadius: SettingsStyle.controlRadius, style: .continuous)
                    .fill(SettingsStyle.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsStyle.controlRadius, style: .continuous)
                    .strokeBorder(SettingsStyle.hairline, lineWidth: 1)
            )
    }
}
