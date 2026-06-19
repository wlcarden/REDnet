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

RUN yarn install --frozen-lockfile
RUN yarn build
COPY config.json ./webapp/config.json
# REDnet brand logo — config branding.auth_header_logo_url points here. Replace branding/ to white-label.
COPY branding/rednet-logo.svg ./webapp/themes/element/img/logos/rednet.svg
COPY branding/favicon.svg ./webapp/vector-icons/favicon.svg
RUN sed -i 's|<link rel="shortcut icon" href="vector-icons/favicon\.[^"]*\.ico">|<link rel="icon" href="vector-icons/favicon.svg" type="image/svg+xml">|' webapp/index.html

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

# --- serve the static SPA on :80; the front Caddy reverse-proxies to this ---
# caddy:2-alpine v2.11.4
FROM caddy@sha256:77c07d5ebfa5be9fd6c820d2094ae662c9e7eeb9bf98346b7f639900263ee2a2 AS serve
COPY --from=build /src/webapp /srv/element
RUN printf ':80 {\n\troot * /srv/element\n\ttry_files {path} /index.html\n\tfile_server\n}\n' > /etc/caddy/Caddyfile
EXPOSE 80
