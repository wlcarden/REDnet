# REDnet brand identity

Canonical reference for the visual system. Every UI surface, document, and asset
should trace back to the tokens defined here.

## Mark

The mesh-node hexagon: six outer nodes radiating from a center node, connected by
spokes and enclosed in a hexagonal outline. Represents a secure network cell.

| Variant      | File                                          | Use                       |
| ------------ | --------------------------------------------- | ------------------------- |
| Wordmark     | `deploy/element-web/branding/rednet-logo.svg` | Auth header, docs, GitHub |
| Favicon/icon | `deploy/element-web/branding/favicon.svg`     | Browser tab, PWA          |

The wordmark splits the name: **RED** in `#E5484D`, **net** in `#8B8D98` (dark) or
`#3C3F44` (light). Both variants use Inter 700, letter-spacing -0.5px.

## Color

### Accent

| Token     | Value                     | Use                              |
| --------- | ------------------------- | -------------------------------- |
| Red       | `#E5484D`                 | Brand mark, buttons, links       |
| Red dim   | `rgba(229, 72, 77, 0.15)` | Selected states, tinted surfaces |
| Red hover | `#DC3D43`                 | Button hover                     |
| Red press | `#CE2C31`                 | Button pressed                   |

### Surfaces (dark theme)

| Token  | Value                       | Use                             |
| ------ | --------------------------- | ------------------------------- |
| Base   | `#111316`                   | Page background, left panel     |
| Ground | `#16181B`                   | Timeline, room list, favicon bg |
| Card   | `#1C1F23`                   | Dialogs, cards, raised panels   |
| Raised | `#23262B`                   | Hover states, active selections |
| Border | `rgba(255, 255, 255, 0.06)` | Panel dividers, input borders   |

### Text

| Token   | Value     | Use                        |
| ------- | --------- | -------------------------- |
| Primary | `#ECEDEE` | Headings, body text        |
| Muted   | `#8B8D98` | Secondary text, timestamps |
| Subtle  | `#62646C` | Captions, disabled, labels |

### Semantic

| Token    | Value     | Use                        |
| -------- | --------- | -------------------------- |
| Secure   | `#30A46C` | Verified, encryption OK    |
| Caution  | `#E5A536` | Warnings, exposure notices |
| Critical | `#FF6369` | Errors, failed states      |

## Typography

Inter is the primary typeface (matches Element's default). Falls back to
`system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif`.

| Role          | Size | Weight | Tracking | Notes                    |
| ------------- | ---- | ------ | -------- | ------------------------ |
| Brand title   | 30px | 700    | -0.5px   | Wordmark only            |
| Page heading  | 20px | 600    | -0.3px   | Top-level section titles |
| Dialog title  | 15px | 600    | -0.2px   | Modal headers            |
| Body          | 13px | 400    | 0        | Content text, in muted   |
| Label/caption | 10px | 600    | 1.5px    | Uppercase, in subtle     |
| Passphrase    | 14px | 400    | 0.5px    | Monospace, on dim bg     |

Monospace stack for passphrases and code: `'SF Mono', 'Fira Code', 'Cascadia Code',
'JetBrains Mono', monospace`.

## Voice

| Trait  | Rule                                       | Example                                        |
| ------ | ------------------------------------------ | ---------------------------------------------- |
| Direct | Imperative, second person, no hedging      | "Write it down somewhere safe and offline."    |
| Honest | Name the limits. No aspirational claims    | "The server can see who you message and when." |
| Calm   | State facts. No caps, no alarm language    | "No one can recover it for you."               |
| Plain  | No jargon without explanation. Short words | "Messages auto-delete after a few days."       |

## Design principles

1. **Geometry over ornament.** The hex grid gives the visual DNA. No gradients, drop
   shadows, rounded illustrations, or decorative textures.

2. **Calm until it matters.** Neutral surfaces dominate. Red appears for brand, actions,
   and real danger. Green for verified state. Amber for exposure warnings.

3. **Two steps to the room list.** Every screen earns its existence. No wizards,
   intermediate states, or confirmation chains between login and the conversation.

## Implementation

| Layer           | File                                                 | What it controls                                   |
| --------------- | ---------------------------------------------------- | -------------------------------------------------- |
| Theme           | `deploy/element-web/config.json.template`            | `custom_themes[0]`: accent, surfaces, text colors  |
| CSS overrides   | `deploy/element-web/branding/rednet-overrides.css`   | Auth page, buttons, dialogs, scrollbars, inputs    |
| Recovery dialog | `deploy/element-web/src/RednetRecoveryKeyDialog.tsx` | Passphrase display uses `.rednet-passphrase` class |
| Wordmark        | `deploy/element-web/branding/rednet-logo.svg`        | Auth header logo                                   |
| Favicon         | `deploy/element-web/branding/favicon.svg`            | Browser tab icon                                   |
| Build injection | `deploy/element-web/Dockerfile`                      | Copies assets, injects CSS `<link>`                |

## White-labelling

Deployers swap assets and config to rebrand. See [BRANDING.md](deploy/element-web/BRANDING.md)
for the full table. The palette tokens in the custom theme and CSS overlay are the
starting points for a rebranded deployment.
