# Icon provenance — design/icons/

Every icon drawing embedded in `design/hud-design-system.html` comes from here.

## Upstream

| field | value |
|---|---|
| project | Lucide (https://lucide.dev, https://github.com/lucide-icons/lucide) |
| version | **1.47.0**, released 2026-09-17 |
| artifact | `lucide-icons-1.47.0.zip`, GitHub release asset 569710846 |
| artifact sha256 | `84aa2931525f129cc3ed2530dd079feb8470b575d56d1fb4fa7404b185af058e` — GitHub's published digest, re-hashed after download and matched |
| licence | ISC, plus MIT for Feather-derived icons. `LICENSE` here is the file at tag `1.47.0`, sha256 `b495047bd93a9b06913511076f504daba17d5bbeb3e0650f3bb53a4220329c57` |

## Where the notices live

- `design/icons/LICENSE` — the upstream text, verbatim and unmodified.
- `design/hud-design-system.html` — an HTML comment carrying the ISC copyright
  and permission notice, because the file embeds copies of the artwork and ISC
  requires the notice to travel with every copy. A visible credit sits under the
  Iconography lede.

These icons are **documentation only**. They are not in `Resources/`, never reach
`Reed.app`, and so are not part of the packaged third-party notice set that
`scripts/build/package-notices.py` builds.

## What replaced what

Each row: the SF Symbol the app renders, the Lucide icon standing in for it here,
the ink colour, the sha256 of the Apple-derived PNG that previously occupied that
slot, the sha256 of the upstream SVG in this directory, and the sha256 of the
exact bytes embedded in the HTML (the upstream file with `stroke="currentColor"`
replaced by the ink colour and whitespace collapsed).

| SF Symbol (app) | Lucide icon | ink | previous PNG sha256 | upstream SVG sha256 | embedded sha256 |
|---|---|---|---|---|---|
| `accessibility` | `accessibility` | `#1c1c21` | `3affad5cd421…` | `114a9b6983ee…` | `f30f1b2f5177…` |
| `arrow.triangle.2.circlepath` | `refresh-cw` | `#1c1c21` | `6aea9afc19ae…` | `2e10dd403c85…` | `5c201c1e9576…` |
| `arrow.up.right` | `arrow-up-right` ¹ | `#1c1c21` | `dfd5ddd91a73…` | `50b2503b9d11…` | `bfb8826cd0b2…` |
| `bubble.left` | `message-square` | `#1c1c21` | `535bd1b74c6c…` | `5812a3be783f…` | `f436d68c3748…` |
| `chart.bar` | `chart-column` | `#1c1c21` | `0629e330c3a0…` | `80664a4c5ca1…` | `953cac87b4e2…` |
| `checkmark` | `check` ¹ | `#1c1c21` | `0efaef00a985…` | `7f33acc9a77a…` | `99c04274aa27…` |
| `checkmark.circle.fill` | `circle-check` | `#1c1c21` | `aaa38b603471…` | `9711e045a599…` | `3f65f591d6e0…` |
| `chevron.up.chevron.down` | `chevrons-up-down` | `#1c1c21` | `ccd43bf0063b…` | `edc561e007cf…` | `04ba01a801bf…` |
| `doc.on.doc` | `copy` | `#1c1c21` | `e901fe6cfcb2…` | `ea80e566c7a1…` | `f02f3aa142b2…` |
| `exclamationmark.bubble` | `message-square-warning` | `#1c1c21` | `f03dc269050f…` | `66e83a1ad0a5…` | `1e8e4648b152…` |
| `exclamationmark.circle.fill` | `circle-alert` ¹ | `#1c1c21` | `97d29f2f96fb…` | `ce3e98b7a03b…` | `f0c8dd872a15…` |
| `exclamationmark.triangle` | `triangle-alert` ¹ | `#1c1c21` | `c3a395736ac4…` | `4866f38b8560…` | `5a57fa99ab57…` |
| `exclamationmark.triangle.fill` | `triangle-alert` ¹ | `#1c1c21` | `510a0183af6b…` | `4866f38b8560…` | `5a57fa99ab57…` |
| `gearshape` | `settings` | `#1c1c21` | `94fc1c5d6b45…` | `0ae27fd0f819…` | `f71eed4d2554…` |
| `hand.raised` | `hand` | `#1c1c21` | `3a8fe920ebf1…` | `fe3771fa2f0a…` | `98893667a4e9…` |
| `hand.raised (white)` | `hand` | `#ffffff` | `bd2225dc0df3…` | `fe3771fa2f0a…` | `5bf0d119fe1a…` |
| `hourglass` | `hourglass` | `#1c1c21` | `a481d2691085…` | `76475d4ca329…` | `3e8445dd5128…` |
| `info.circle` | `info` ¹ | `#1c1c21` | `19856793b4e7…` | `bc977a64eb96…` | `cc287be8cbc4…` |
| `info.circle (white)` | `info` ¹ | `#ffffff` | `1f1ea38db753…` | `bc977a64eb96…` | `e225f839c593…` |
| `keyboard` | `keyboard` | `#1c1c21` | `c32331ac5dc3…` | `f509925ca819…` | `b1b5e9582e8b…` |
| `keyboard (white)` | `keyboard` | `#ffffff` | `00949fbc2d79…` | `f509925ca819…` | `1004b20d6a0c…` |
| `ladybug` | `bug` | `#1c1c21` | `c8a18d7329ce…` | `c4fddf0d43b4…` | `b2fa3ffb029c…` |
| `list.bullet` | `list` | `#1c1c21` | `285a30135d22…` | `ff97a7379eb9…` | `87edcce829c6…` |
| `lock.shield` | `shield-check` | `#1c1c21` | `2ea1a2436a0f…` | `8d4fcdbde5bb…` | `acdaea02a69d…` |
| `lock.shield (white)` | `shield-check` | `#ffffff` | `a2d4180a3852…` | `8d4fcdbde5bb…` | `82a173b84247…` |
| `mic` | `mic` | `#1c1c21` | `e6d8a632dfef…` | `9b940cd735d1…` | `2befa441d68d…` |
| `mic.fill` | `mic` | `#1c1c21` | `fcf485a3b658…` | `9b940cd735d1…` | `2befa441d68d…` |
| `mic.slash` | `mic-off` | `#1c1c21` | `45d9e6dc0a98…` | `bcb5a033b4ec…` | `b408ae7692c3…` |
| `power` | `power` ¹ | `#1c1c21` | `a64e32a41f96…` | `1e6b84a659aa…` | `b1b8b5ea0e57…` |
| `sparkles` | `sparkles` | `#1c1c21` | `48d11c1cb342…` | `f5499f33f09d…` | `da95089710ca…` |
| `xmark` | `x` ¹ | `#1c1c21` | `b50545acf9f8…` | `4a9cdab38fbb…` | `eea4fa273791…` |
| `xmark.octagon.fill` | `octagon-x` ¹ | `#1c1c21` | `330dfa23ba5f…` | `6ca17c136a1a…` | `fefa123440d1…` |

¹ Feather-derived, MIT (Cole Bemis) as well as ISC — see `LICENSE`.

## Known limits

- Lucide has no filled variants, so an SF name ending `.fill` may share a drawing
  with its outline sibling (`mic` / `mic.fill`, `exclamationmark.triangle` /
  `.fill`). The page says so, and the name is the authority, not the drawing.
- The stand-ins are not visually identical to SF Symbols and are not meant to be.
  They carry the meaning; the app still renders the SF Symbol named in each row.
- No Apple drawing was traced, redrawn or used as a reference: each replacement
  was chosen by the symbol's meaning and taken unmodified from upstream except
  for the stroke colour.
