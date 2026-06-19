# White-labelling the REDnet client

Everything a deployment changes to make the client _theirs_. Most is config or a single asset swap; nothing
here requires forking. Rebuild the client (`./build.sh`) after changing assets or config.

| What                     | Where                                                         | Default → change to                                                                                                                                                                                  |
| ------------------------ | ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Brand name**           | `rednet.env` → `REDNET_BRAND`                                 | `REDnet` → your community name. Flows into the app title, the Space name, and the exposure-notice copy.                                                                                              |
| **Homeserver**           | `rednet.env` → `REDNET_DOMAIN` (immutable after first deploy) | your domain. Locks the client to your server.                                                                                                                                                        |
| **Auth/header logo**     | `element-web/branding/rednet-logo.svg`                        | the default mesh-node wordmark → your logo. Wired into the build (Dockerfile copies it to the path `config.branding.auth_header_logo_url` references). Keep it legible on light **and** dark.        |
| **Favicon / app icon**   | `element-web/branding/favicon.svg`                            | the default square mark. Wired in the Dockerfile (`COPY` + `sed` replaces the `.ico` link with an SVG `<link>` in `index.html`). Replace `favicon.svg` with your own.                                |
| **Theme**                | `config.json.template` → `default_theme` (`dark`)             | dark is the default. For brand colours, add a `setting_defaults.custom_themes` entry (Element's custom-theme schema) and set `default_theme` to it. The base palette is intentionally neutral.       |
| **Exposure notice copy** | `config.json.template` → `user_notice`                        | the Tier-1 "what's private / what's not" banner. Reword for your community; keep the honesty (content E2EE, metadata visible). `show_once:true` = shown once per device; set `false` for persistent. |
| **Welcome primer**       | `bootstrap-rooms.sh` → `PRIMER` (set as `#welcome`'s topic)   | the in-room orientation. Reword to match your community + Tier-2 tool.                                                                                                                               |
| **Stripped features**    | `config.json.template` → `UIFeature.*`, `features.*`          | url-previews/widgets/guests/registration/etc. are off by hardening — leave off unless you understand the metadata/UX tradeoff (ARCHITECTURE §6).                                                     |

**Mobile (Element X)** is stock and can't be deeply branded on the budget path — either a DIY `element-x-*`
build (your own Apple/Google developer accounts) or just homeserver-lock the stock app via MDM / a deep-link
(`account_provider=`). See ARCHITECTURE §7.

**What's already wired (no deployer action):** homeserver lock, brand name, dark theme, the heavy
feature-stripping, the auth-header logo, the exposure notice, and the silent-onboarding module + patch.
