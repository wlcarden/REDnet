# syntax=docker/dockerfile:1
# REDnet Element Web soft fork.
# ⚠️ NOT built in-sandbox — this is a heavy webpack build. Build it at deploy time with ./build.sh.
# PIN ELEMENT_VERSION to an exact upstream tag and VALIDATE integration.patch against THAT tag
# (the build warns + continues without silent onboarding if the patch no longer applies).
ARG ELEMENT_VERSION=v1.11.86
# R2: a git TAG is movable (can be re-pointed upstream). For production, also pin the exact commit SHA.
ARG ELEMENT_COMMIT=

# Base images digest-pinned (2026-06-16; re-verify at deploy — PRODUCTION.md #2).
# node:22-bookworm (Dockerfiles have no inline comments — annotation must be its own line)
FROM node@sha256:2d178f2785b96dfbf62a416ca2e40f50e30150b4ff3320d706f0d96e90600eb3 AS build
ARG ELEMENT_VERSION
ARG ELEMENT_COMMIT
WORKDIR /src
RUN git clone --depth 1 --branch "${ELEMENT_VERSION}" https://github.com/element-hq/element-web.git . \
 && if [ -n "${ELEMENT_COMMIT}" ]; then \
      [ "$(git rev-parse HEAD)" = "${ELEMENT_COMMIT}" ] || { echo "Element HEAD $(git rev-parse HEAD) != pinned ${ELEMENT_COMMIT}"; exit 1; }; \
      echo "Element commit pinned: ${ELEMENT_COMMIT}"; \
    else echo "R2 WARNING: ELEMENT_COMMIT not set — building from the MOVABLE tag ${ELEMENT_VERSION}. Pin the commit SHA for production."; fi

# --- REDnet soft-fork overlay: a MODULE (cryptoSetup extension) + a minimal PATCH (the login trigger) + the dialog ---
# 1) the onboarding module — registers the cryptoSetup extension; bundled into the app via build_config.yaml.
COPY rednet-module ./rednet-module
COPY build_config.yaml ./build_config.yaml
WORKDIR /src/rednet-module
RUN npm install --no-audit --no-fund --loglevel=error && npm run build   # -> lib/index.js
WORKDIR /src
# 2) the soft-fork UI the patch renders (recovery-passphrase show/prompt dialog).
COPY src/RednetRecoveryKeyDialog.tsx ./src/RednetRecoveryKeyDialog.tsx
# 3) the minimal postLoginSetup patch that calls the module. Graceful: if it no longer applies, the build
#    still yields a branded client locked to our server, with Element's stock onboarding.
COPY integration.patch ./integration.patch
RUN git apply --whitespace=fix integration.patch \
      && echo "REDnet: onboarding patch APPLIED" \
   || echo "REDnet WARNING: integration.patch did not apply to ${ELEMENT_VERSION}. Re-anchor it (see README). Building WITHOUT silent onboarding."

# 4) hide the native Create Room / Create Space / Explore UI. Room creation is
#    locked server-side (synapse-modules/rednet_room_policy) — these stock buttons
#    now dead-end in a 403, so a ComponentVisibility customisation removes them.
#    customisations.json (repo root) overrides the default customisation module.
COPY src/RednetComponentVisibility.ts ./src/customisations/RednetComponentVisibility.ts
COPY customisations.json ./customisations.json

# 5) hide upstream affordances our security model makes leaky/broken: Export chat
#    (one-click full decrypted-history exfil) and native Report (routes the message
#    + reason to the homeserver admin — our threat surface), plus the dead-ending
#    Add-extensions button. Unlike Create, these are hardcoded in the components, so
#    a source patch is required. FATAL if it stops applying (unlike the onboarding
#    patch): refuse to ship a client that still exposes these. Re-anchor per README.
COPY hide-affordances.patch ./hide-affordances.patch
RUN git apply --whitespace=fix hide-affordances.patch \
      && echo "REDnet: hide-affordances patch APPLIED (Export + Report + Add-extensions removed)" \
   || { echo "REDnet FATAL: hide-affordances.patch did not apply to ${ELEMENT_VERSION}. Re-anchor it (README). Refusing to build a client that still exposes Export chat / native Report."; exit 1; }

# 6) the POSITIVE affordance replacing native creation: a "Request a room or space"
#    plus-menu item that opens a dialog and sends `!gov request` to the @rednet-gov DM
#    (organizer-reviewed). A dialog component + a patch to RoomListHeader. Graceful: if
#    the patch stops applying, the client still works (members request via the command,
#    which the guides document) — so warn, don't fail.
COPY src/RednetRequestRoomDialog.tsx ./src/components/views/dialogs/RednetRequestRoomDialog.tsx
COPY request-room-button.patch ./request-room-button.patch
RUN git apply --whitespace=fix request-room-button.patch \
      && echo "REDnet: request-room-button patch APPLIED" \
   || echo "REDnet WARNING: request-room-button.patch did not apply to ${ELEMENT_VERSION}. Re-anchor it (README). Building WITHOUT the Request button (members use !gov request)."

# 7) gate the 1:1 header call buttons on the calls profile (feature_group_calls).
#    They render regardless of any config in stock Element, but REDnet has no legacy
#    1:1 VoIP path (P2P off, no TURN), so with calls off (default) they only dead-end.
#    Graceful: a non-applying patch just leaves the (inert) buttons visible.
COPY gate-call-buttons.patch ./gate-call-buttons.patch
RUN git apply --whitespace=fix gate-call-buttons.patch \
      && echo "REDnet: gate-call-buttons patch APPLIED" \
   || echo "REDnet WARNING: gate-call-buttons.patch did not apply to ${ELEMENT_VERSION}. Re-anchor it (README). Building WITHOUT call-button gating."

# 8) the coercion/duress control: a confirm-gated "Panic — wipe this device" item
#    in the user menu that sends `!duress` to the @rednet-gov DM (the gov bot
#    self-locks the sender's account + alerts organizers) and then fully signs out
#    and clears the local store (crypto keys + session). A dialog component + a
#    patch to UserMenu. Graceful: if the patch stops applying, the client still
#    works — a member can type `!duress` in their gov-bot DM by hand — so warn,
#    don't fail.
COPY src/RednetPanicDialog.tsx ./src/components/views/dialogs/RednetPanicDialog.tsx
COPY panic-button.patch ./panic-button.patch
RUN git apply --whitespace=fix panic-button.patch \
      && echo "REDnet: panic-button patch APPLIED" \
   || echo "REDnet WARNING: panic-button.patch did not apply to ${ELEMENT_VERSION}. Re-anchor it (README). Building WITHOUT the panic menu item (members use !duress by hand)."

# 9) Wave-1 legibility UI (make the governance model visible), all graceful:
#    - role-labels.patch: repoints Roles.ts + EntityTile so power levels read as
#      REDnet roles (Member/Moderator/Organizer/Admin, incl. a PL75 Organizer tier).
#    - retention-indicator.patch + RednetRetentionPill: a room-header pill showing
#      the disappearing-message window (per-room m.room.retention, else the
#      config default org.rednet.retention.default_days; durable rooms show none).
#    - governance-nav.patch + RednetGovernanceButton: an organizer-only space-panel
#      button opening the /governance/ dashboard.
COPY src/RednetRetentionPill.tsx ./src/components/views/rooms/RednetRetentionPill.tsx
COPY src/RednetGovernanceButton.tsx ./src/components/views/spaces/RednetGovernanceButton.tsx
# RednetGovernanceButton opens a menu including Pending requests (approve/deny),
# so the requests dialog must be present before the build.
COPY src/RednetRequestsDialog.tsx ./src/components/views/dialogs/RednetRequestsDialog.tsx
# ...and the invite dialog it can open from the same governance menu.
COPY src/RednetInviteDialog.tsx ./src/components/views/dialogs/RednetInviteDialog.tsx
COPY role-labels.patch ./role-labels.patch
COPY retention-indicator.patch ./retention-indicator.patch
COPY governance-nav.patch ./governance-nav.patch
RUN git apply --whitespace=fix role-labels.patch \
      && echo "REDnet: role-labels patch APPLIED" \
   || echo "REDnet WARNING: role-labels.patch did not apply to ${ELEMENT_VERSION}. Re-anchor it (README). Building WITHOUT REDnet role labels."
RUN git apply --whitespace=fix retention-indicator.patch \
      && echo "REDnet: retention-indicator patch APPLIED" \
   || echo "REDnet WARNING: retention-indicator.patch did not apply to ${ELEMENT_VERSION}. Re-anchor it (README). Building WITHOUT the retention pill."
RUN git apply --whitespace=fix governance-nav.patch \
      && echo "REDnet: governance-nav patch APPLIED" \
   || echo "REDnet WARNING: governance-nav.patch did not apply to ${ELEMENT_VERSION}. Re-anchor it (README). Building WITHOUT the governance dashboard button."

# 10) message "Report to organizers" — the coercion-aware replacement for the
#     native Report we removed (hide-affordances). Adds a MessageContextMenu item
#     that sends `!report @sender` to the @rednet-gov DM (gov bot alerts organizers).
#     Shares MessageContextMenu.tsx with hide-affordances.patch but the hunks don't
#     overlap (verified applies to both the pristine + hide-affordances-patched tree).
#     Graceful: members can still !report in their gov-bot DM by hand.
COPY src/RednetReportDialog.tsx ./src/components/views/dialogs/RednetReportDialog.tsx
COPY report-to-organizers.patch ./report-to-organizers.patch
RUN git apply --whitespace=fix report-to-organizers.patch \
      && echo "REDnet: report-to-organizers patch APPLIED" \
   || echo "REDnet WARNING: report-to-organizers.patch did not apply to ${ELEMENT_VERSION}. Re-anchor it (README). Building WITHOUT the Report-to-organizers item (members use !report by hand)."

# 11) organizer-only member governance: a "Manage member" item in the UserInfo
#     panel (PL>=75-gated) that runs the same !gov role / !gov revoke commands as
#     #gov-bot, from a right-click. A dialog component + a UserInfo patch. Graceful:
#     organizers still have the chat commands in #gov-bot.
COPY src/RednetMemberGovDialog.tsx ./src/components/views/dialogs/RednetMemberGovDialog.tsx
COPY member-gov-actions.patch ./member-gov-actions.patch
RUN git apply --whitespace=fix member-gov-actions.patch \
      && echo "REDnet: member-gov-actions patch APPLIED" \
   || echo "REDnet WARNING: member-gov-actions.patch did not apply to ${ELEMENT_VERSION}. Re-anchor it (README). Building WITHOUT the Manage-member button (organizers use !gov in #gov-bot)."

# 12) first-run onboarding checklist: a one-time in-app safety modal after login
#     (save passphrase, kill lock-screen previews, keep identity out of chat, know
#     retention). A dialog + a MatrixChat patch on onShowPostLoginScreen (shown once
#     via a localStorage flag). DELIBERATELY SEPARATE from integration.patch (the
#     recovery-critical silent-onboarding hook) — verified to compose with it.
#     Graceful: onboarding is unaffected if this patch stops applying.
COPY src/RednetOnboardingDialog.tsx ./src/components/views/dialogs/RednetOnboardingDialog.tsx
COPY onboarding-checklist.patch ./onboarding-checklist.patch
RUN git apply --whitespace=fix onboarding-checklist.patch \
      && echo "REDnet: onboarding-checklist patch APPLIED" \
   || echo "REDnet WARNING: onboarding-checklist.patch did not apply to ${ELEMENT_VERSION}. Re-anchor it (README). Building WITHOUT the first-run checklist."

# 13) vouch provenance: "Vouched by @x" in the UserInfo panel (the trust chain).
#     Fetches the gov-bot's vouch graph from /governance/data/vouch.jsonl (now served
#     behind a valid Matrix OpenID token — mint_endpoint _serve_vouch) with
#     cli.getOpenIdToken(), finds the account's `claimed` record. A component + a
#     UserInfo patch (shares UserInfo.tsx with member-gov-actions.patch — hunks don't
#     overlap; verified applies to both pristine + member-gov-patched tree). Graceful.
COPY src/RednetVouchProvenance.tsx ./src/components/views/right_panel/RednetVouchProvenance.tsx
COPY vouch-provenance.patch ./vouch-provenance.patch
RUN git apply --whitespace=fix vouch-provenance.patch \
      && echo "REDnet: vouch-provenance patch APPLIED" \
   || echo "REDnet WARNING: vouch-provenance.patch did not apply to ${ELEMENT_VERSION}. Re-anchor it (README). Building WITHOUT vouch provenance in profiles."

# 14) room lifecycle: organizer/admin Archive/Delete actions in a room's right-click
#     menu, each behind a typed-confirm dialog, sending `!gov archive|delete <roomId>`
#     to #gov-bot. A dialog + a gated options component + a RoomGeneralContextMenu patch.
#     Graceful: organizers still have the chat commands.
COPY src/RednetRoomLifecycleDialog.tsx ./src/components/views/dialogs/RednetRoomLifecycleDialog.tsx
COPY src/RednetRoomLifecycleOptions.tsx ./src/components/views/context_menus/RednetRoomLifecycleOptions.tsx
COPY room-lifecycle.patch ./room-lifecycle.patch
RUN git apply --whitespace=fix room-lifecycle.patch \
      && echo "REDnet: room-lifecycle patch APPLIED" \
   || echo "REDnet WARNING: room-lifecycle.patch did not apply to ${ELEMENT_VERSION}. Re-anchor it (README). Building WITHOUT room archive/delete menu items (organizers use !gov)."

RUN yarn install --frozen-lockfile
RUN yarn build
COPY config.json ./webapp/config.json
# REDnet brand logo — config branding.auth_header_logo_url points here. Replace branding/ to white-label.
COPY branding/rednet-logo.svg ./webapp/themes/element/img/logos/rednet.svg
COPY branding/favicon.svg ./webapp/vector-icons/favicon.svg
COPY branding/rednet-overrides.css ./webapp/rednet-overrides.css
COPY branding/join.html ./webapp/join.html
COPY branding/operator-guide.html ./webapp/operator-guide.html
COPY branding/moderator-guide.html ./webapp/moderator-guide.html
COPY branding/member-guide.html ./webapp/member-guide.html
COPY branding/home.html ./webapp/home.html
COPY branding/safety.html ./webapp/safety.html
COPY governance-widget/index.html ./webapp/governance/index.html
RUN sed -i 's|<link rel="shortcut icon" href="vector-icons/favicon\.[^"]*\.ico">|<link rel="icon" href="vector-icons/favicon.svg" type="image/svg+xml">|' webapp/index.html \
 && sed -i 's|</head>|<link rel="stylesheet" href="rednet-overrides.css">\n</head>|' webapp/index.html

# R2: a SILENT integration.patch miss ships STOCK onboarding — a recovery-capability regression (Security
# Key, not the passphrase; breaks N=1 / new-device recovery), yet the build still exits 0. Make it
# MACHINE-DETECTABLE: grep the built bundle for a sentinel present ONLY when the soft-fork module is wired
# in (it's tree-shaken out if the patch didn't apply), write a marker, warn loudly, and fail when asked.
ARG REDNET_REQUIRE_SILENT_ONBOARDING=0
RUN if grep -rqlF 'Save your recovery passphrase' webapp/ 2>/dev/null; then \
      echo "REDNET_SILENT_ONBOARDING=on"  > webapp/rednet-build.txt; echo "REDnet: silent onboarding IS in the bundle (verified)"; \
    else \
      echo "REDNET_SILENT_ONBOARDING=off" > webapp/rednet-build.txt; \
      echo "REDnet XXX silent onboarding NOT in the bundle — recovery degraded to STOCK Element (breaks N=1 / new-device). Re-anchor integration.patch (see README)."; \
      [ "$REDNET_REQUIRE_SILENT_ONBOARDING" = "1" ] && exit 1 || true; \
    fi

# Verify the room/space-creation UI lockdown was actually bundled: our customisation
# logs a distinctive line at module load, which webpack keeps only if customisations.json
# wired it in. If it's missing, the Create Room/Space buttons are still visible.
RUN if grep -rqlF 'native room/space creation hidden' webapp/ 2>/dev/null; then \
      echo "REDnet: Create Room/Space UI hidden (ComponentVisibility customisation wired)"; \
    else \
      echo "REDnet WARNING: ComponentVisibility customisation NOT bundled — native Create Room/Space buttons still visible. Check customisations.json + the UIComponent path against ${ELEMENT_VERSION}."; \
    fi

# Verify the "Request a room or space" affordance bundled — the label is a distinctive
# hardcoded string webpack keeps only if the patch wired the menu item in (the dialog is
# tree-shaken out otherwise). If missing, the plus-menu has no Request item.
RUN if grep -rqlF 'Request a room or space' webapp/ 2>/dev/null; then \
      echo "REDnet: Request-a-room button bundled"; \
    else \
      echo "REDnet WARNING: Request-a-room button NOT bundled — re-anchor request-room-button.patch + check RednetRequestRoomDialog imports against ${ELEMENT_VERSION}."; \
    fi

# Verify the panic/duress control bundled — 'wipe this device' is a distinctive
# hardcoded string (ASCII, so no em-dash re-encoding risk) that webpack keeps only
# if the patch wired the menu item in (the dialog is tree-shaken out otherwise).
# If missing, the user menu has no Panic item (members fall back to typing !duress).
RUN if grep -rqlF 'wipe this device' webapp/ 2>/dev/null; then \
      echo "REDnet: Panic/duress control bundled"; \
    else \
      echo "REDnet WARNING: Panic control NOT bundled — re-anchor panic-button.patch + check RednetPanicDialog imports against ${ELEMENT_VERSION}."; \
    fi

# Wave-1 legibility sentinels (each a distinctive hardcoded string webpack keeps
# only if the corresponding patch/component wired in). Graceful — warn, don't fail.
RUN if grep -rqlF 'Organizer' webapp/ 2>/dev/null; then \
      echo "REDnet: role labels bundled"; \
    else echo "REDnet WARNING: role-labels NOT bundled — re-anchor role-labels.patch against ${ELEMENT_VERSION}."; fi
RUN if grep -rqlF 'Messages here disappear after' webapp/ 2>/dev/null; then \
      echo "REDnet: retention indicator bundled"; \
    else echo "REDnet WARNING: retention pill NOT bundled — re-anchor retention-indicator.patch + check RednetRetentionPill imports against ${ELEMENT_VERSION}."; fi
RUN if grep -rqlF 'Pending requests' webapp/ 2>/dev/null; then \
      echo "REDnet: pending-requests dialog bundled"; \
    else echo "REDnet WARNING: pending-requests dialog NOT bundled — check RednetRequestsDialog + RednetGovernanceButton menu against ${ELEMENT_VERSION}."; fi
RUN if grep -rqlF 'Invite someone' webapp/ 2>/dev/null; then \
      echo "REDnet: invite dialog bundled"; \
    else echo "REDnet WARNING: invite dialog NOT bundled — check RednetInviteDialog + RednetGovernanceButton menu against ${ELEMENT_VERSION}."; fi
RUN if grep -rqlF 'Governance dashboard' webapp/ 2>/dev/null; then \
      echo "REDnet: governance nav button bundled"; \
    else echo "REDnet WARNING: governance button NOT bundled — re-anchor governance-nav.patch + check RednetGovernanceButton imports against ${ELEMENT_VERSION}."; fi
RUN if grep -rqlF 'Report to organizers' webapp/ 2>/dev/null; then \
      echo "REDnet: report-to-organizers bundled"; \
    else echo "REDnet WARNING: report-to-organizers NOT bundled — re-anchor report-to-organizers.patch + check RednetReportDialog imports against ${ELEMENT_VERSION}."; fi
RUN if grep -rqlF 'Manage member' webapp/ 2>/dev/null; then \
      echo "REDnet: member-gov-actions bundled"; \
    else echo "REDnet WARNING: member-gov-actions NOT bundled — re-anchor member-gov-actions.patch + check RednetMemberGovDialog imports against ${ELEMENT_VERSION}."; fi
RUN if grep -rqlF 'keeps you safer here' webapp/ 2>/dev/null; then \
      echo "REDnet: onboarding checklist bundled"; \
    else echo "REDnet WARNING: onboarding checklist NOT bundled — re-anchor onboarding-checklist.patch + check RednetOnboardingDialog imports against ${ELEMENT_VERSION}."; fi
RUN if grep -rqlF 'Vouched by' webapp/ 2>/dev/null; then \
      echo "REDnet: vouch provenance bundled"; \
    else echo "REDnet WARNING: vouch provenance NOT bundled — re-anchor vouch-provenance.patch + check RednetVouchProvenance imports against ${ELEMENT_VERSION}."; fi
RUN if grep -rqlF 'Confirm vouch' webapp/ 2>/dev/null; then \
      echo "REDnet: confirm-vouch action bundled"; \
    else echo "REDnet WARNING: confirm-vouch NOT bundled — check RednetMemberGovDialog + RednetVouchProvenance edits against ${ELEMENT_VERSION}."; fi
RUN if grep -rqlF 'Archive room' webapp/ 2>/dev/null; then \
      echo "REDnet: room-lifecycle actions bundled"; \
    else echo "REDnet WARNING: room-lifecycle NOT bundled — re-anchor room-lifecycle.patch + check RednetRoomLifecycle* imports against ${ELEMENT_VERSION}."; fi

# --- serve the static SPA on :80; the front Caddy reverse-proxies to this ---
# caddy:2-alpine v2.11.4
FROM caddy@sha256:77c07d5ebfa5be9fd6c820d2094ae662c9e7eeb9bf98346b7f639900263ee2a2 AS serve
COPY --from=build /src/webapp /srv/element
RUN printf ':80 {\n\troot * /srv/element\n\t@join path /join /join/\n\trewrite @join /join.html\n\t@opguide path /operator-guide /operator-guide/\n\trewrite @opguide /operator-guide.html\n\t@modguide path /moderator-guide /moderator-guide/\n\trewrite @modguide /moderator-guide.html\n\t@memguide path /member-guide /member-guide/\n\trewrite @memguide /member-guide.html\n\t@safety path /safety /safety/\n\trewrite @safety /safety.html\n\ttry_files {path} {path}/index.html /index.html\n\tfile_server\n}\n' > /etc/caddy/Caddyfile
EXPOSE 80
