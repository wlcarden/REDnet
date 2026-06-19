# REDnet — log & metadata hygiene audit (PRODUCTION.md #8)

Audited every surface that could retain **who-talked-when** metadata (client IPs, user-agents, MXID↔IP
links) against the seizable-core threat model. Done 2026-06-16 on the running stack with real login
traffic. Goal: no deanonymizing metadata outlives its configured window, and nothing is **unbounded**.

> ⚠️ **Superseded primary control (security review R2): the CORE no longer sees real client IPs at all.**
> The front forwards a **constant placeholder** (`192.0.2.1`) instead of the client IP (caddy `(sanitize)`),
> so Synapse + MAS record `192.0.2.1` for everyone (verified: `user_ips.ip` / `devices.ip` = `192.0.2.1`).
> **Per-IP rate-limiting moved to the front edge.** This makes everything below — the scrub, the access-log
> suppression, the retention windows — a **defense-in-depth backstop** (in case the placeholder is ever
> reverted or misconfigured), not the primary protection. The real client IP exists only transiently on the
> disposable, log-rotated FRONT. Keep the mitigations below anyway; they no longer carry the whole load.

## Findings & mitigations

| #   | Surface                         | Finding                                                                                                                                                             | Mitigation                                                                                                                                                   | Status                                            |
| --- | ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------- |
| 1   | **MAS database**                | Stores IP/UA across ~13 columns incl. `user_registrations.ip_address` (the IP each account was created from). **No native pruning** — unbounded on a seized core.   | `scrub-metadata.sh` NULLs all MAS IP/UA columns; MAS only re-populates the _current_ session's IP, so scheduling it (hourly) caps retention to one interval. | ✅ built + verified (injected IPs → scrubbed → 0) |
| 2   | **Synapse access log** (stderr) | Per request: `client_ip {@mxid} "GET /path" "UA"` — a who-did-what-when record.                                                                                     | `synapse.access` logger set to `WARN` in the generated log config (setup.sh hardening).                                                                      | ✅ applied + verified (no access line after)      |
| 3   | **Synapse `user_ips` table**    | `user_id → ip → user_agent → last_seen`, one row per device.                                                                                                        | Bounded by `user_ips_max_age: 1d` (already set; table held only rolling entries).                                                                            | ✅ working as designed                            |
| 4   | **Caddy (front) logs** (stderr) | Access logging is **off** by default (good), but _error_ logs (e.g. 502s) include `client_ip`, `uri`, `User-Agent`. The front is the public face → real client IPs. | Bound container-log retention via the Docker daemon (below). The front is also disposable/burnable by design.                                                | ⚠️ bound by log rotation                          |

## Container-log retention (covers #2 residue + #4)

Suppression handles the worst lines; rotation bounds the rest. Set Docker daemon log rotation on every
host (`/etc/docker/daemon.json`), so no container's stderr grows unbounded:

```json
{ "log-driver": "json-file", "log-opts": { "max-size": "5m", "max-file": "2" } }
```

On the FRONT specifically, prefer even tighter (or ship logs to volatile storage), since it carries real
client IPs in error lines and is the box most likely to be seized.

## Residuals (the deliberate windows)

After the above, **who-talked-when is bounded, not eliminated** — which is the honest, correct posture:

- **MAS:** ≤ the scrub interval (e.g. 1 h) of the current session's IP.
- **Synapse `user_ips`:** ≤ 1 day (the `user_ips_max_age` window — the organizing-memory vs exposure dial).
- **Container logs:** ≤ the rotation window (Caddy error lines, any residual).
- **No UNBOUNDED structured IP store remains** once `scrub-metadata.sh` is scheduled — that was the one
  finding that broke the model, and it's closed.

This inventory is the artifact the #1 security review should check against the threat model's claims.

## Operate

```bash
./scrub-metadata.sh    # schedule hourly alongside backup.sh (MAS has no native pruning)
```
