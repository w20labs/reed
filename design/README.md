# Reed UI — design source

Design references for Reed, the free, local dictation app. Open the HTML files
in a browser; they are self-contained, animated mocks.

- **`hud-design-system.html`** — the source of truth. Its segments:
  - **System design** — tokens, type, spacing, motion, elevation, iconography.
  - **Onboarding** — the seven-step first run, including every speech-model and
    Apple Intelligence variant.
  - **Using Reed** — the HUD lifecycle, Bluetooth behavior, telemetry and
    network, the menubar breadcrumb, the mic warning, and developer-only local
    review.
  - **Settings** (`hud-design-system.html#settings`) — the five tabs
    (Dictation, Cleanup, Permissions, Privacy, About) and the speech-model
    repair notice in the menu.
  - **Errors** — every current HUD error headline, with severity and action.
  - **Proposals** — unapproved design changes, if any.
- **`hud-all-states.html`** — companion: every HUD pill state over dark and
  light desktops.
- **`hud-full-flow.html`** — companion: one dictation's adaptive pill,
  Listening → processing → Done.

A design change is a grep and a render: `scripts/design/render-block.sh "<h3 text>" out.png`
renders one block of `hud-design-system.html`.

Design language: the **dark-glass floating pill** is unique to the transient HUD;
the menu and Settings are standard system-appearance surfaces that share the
accents (amber = actionable error, red = hard failure, green = on/success), the
badge/keycap styles, glyphs, and SF Pro / SF Mono type.

The dated decision record, and the standalone proposal pages for accounts,
subscriptions, sign-in, an API/MCP layer, go-to-market and Settings
color/layout variants, are not part of this reference. They describe how the
design arrived here, including retired paid-era features, and they remain in
the repository's history.
