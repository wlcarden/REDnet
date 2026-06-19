# Onboarding PWA — milestone B: MAS delegation + no-PII account creation

The last hard gate of `SPEC §5 Track A`: stand up MAS↔Synapse delegation, create a **no-PII** account programmatically, and chain it to the proven silent E2EE bootstrap (milestone A).

## Result — PASS (2026-06-16, Synapse 1.155.0, MAS :latest / 1.18, matrix-js-sdk 41.8)

**Run:** `bash run.sh` (≈4 min: stands up Postgres + MAS + Synapse delegated, creates a user, mints a token, bootstraps).

End-to-end chain, all green:

```
MAS register-user alice (NO email)        -> MAS user_emails rows: 0   (no PII)
MAS issue-compatibility-token alice       -> mct_… token
whoami via Synapse with that token        -> @alice:rednet.test        ← DELEGATION PROVEN
silent E2EE bootstrap on that account     -> cross-signing + key backup v1, recovery key never shown -> PASS
```

The `whoami` is the proof that **Synapse accepts a MAS-issued token** — i.e. `matrix_authentication_service` delegation is live — and the rest shows a MAS-created, no-PII account bootstrapping full E2EE with zero user-visible prompts.

## The config recipe that worked (definitive, for the real build)

**Synapse `homeserver.yaml`** — the stable block (NOT the old `experimental_features.msc3861` client-ULID dance):

```yaml
matrix_authentication_service:
  enabled: true
  endpoint: http://mas:8080 # where Synapse reaches MAS (internal)
  secret_path: /data/mas_shared_secret # file holds the shared secret (inline `secret` is blocked unless allow_secrets_in_config)
password_config: { enabled: false } # REQUIRED: "Password auth cannot be enabled when OAuth delegation is enabled"
# do NOT also set experimental_features.msc3861 (they conflict); drop enable_registration / registration_shared_secret
```

**MAS `config.yaml`** — shared-secret model; `config generate` then patch only:

```yaml
database: { uri: postgresql://…/mas } # MAS's OWN database (separate from Synapse's)
http: { public_base: https://…/, issuer: https://…/ } # ★ MUST be https in prod (cookie Secure flag)
matrix:
  {
    kind: synapse,
    homeserver: <server_name>,
    secret: <SHARED — same value as Synapse's secret_path>,
    endpoint: http://synapse:8008/,
  }
```

No `clients:` and no `policy:` block are needed for the Synapse integration — the shared `matrix.secret` is the whole handshake.

**No-PII account + session (the PWA backend's job):**

- `mas-cli manage register-user <name> --password <ephemeral> --yes` — **no `--email` = no PII**. (Password is an internal artifact the user never sees.)
- `mas-cli manage issue-compatibility-token <name> <device>` — mints a usable Matrix token. (Production PWA: the HTTP Admin API `POST /api/admin/v1/users` + the equivalent token path; the CLI proves the capability.)

## Finding to fold into the whitelabel config

- MAS warns _"No email address provided, user will need to add one."_ For the **PWA/token flow this is moot** (the user never does an interactive MAS web login — their session comes from the minted token), and the account works fully without email (proven above). But for **interactive logins (Element X / Track B)** MAS may prompt for email on first web login — set MAS `account.password_registration_email_required: false` (and verify there's no "nag existing email-less users" default) to preserve the no-PII guarantee there.

## What's now proven vs remaining for the PWA

- ✅ **A — silent E2EE bootstrap** (milestone A).
- ✅ **B — MAS delegation + no-PII account creation + usable session** (this).
- ▫️ **C — auto-join** the welcome + Reference rooms: trivial server-side `auto_join_rooms` config; low risk, not separately spiked.
- ▫️ **D — Element Web hand-off without a recovery re-nag** (original Spike 02): needs Element Web in the loop; a config/UX check, lower risk than A/B.
- ▫️ Package as a PWA + **security review** (it creates accounts + bootstraps keys for at-risk users).

The two hard, novel unknowns (silent bootstrap; MAS no-PII delegation) are both empirically cleared.
