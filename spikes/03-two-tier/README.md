# Spike 03 — Two-tier topology + media through the proxy hop

**Question:** `SPEC.md §3` puts Synapse+Postgres on a no-public-IP **core** behind a disposable **front** proxy. Does that topology actually work — core unreachable, front the only door — and does **media survive the proxy hop** (the SPEC's media concern)?

**What it does:** Docker stack with Postgres + Synapse (core, **no published ports**) + Caddy (front, the only `:8080` publisher, running the `SPEC §3` reverse-proxy split). Verifies isolation, then registers/logs-in and **round-trips a 10 MB media file through the front**, sha256-checked.

**Run:** `bash run.sh` (≈2 min).

## Result — PASS (2026-06-16, Synapse 1.155.0)

```
ISOLATION: only caddy publishes 0.0.0.0:8080;
  synapse -> 8008/tcp (internal), postgres -> 5432/tcp (internal)  [no host mapping]
login via front: OK
media: uploaded sha256 == downloaded sha256 (10485760 bytes)
PASS
```

**Confirmed:**

- ✅ Core (Synapse + Postgres) runs with **no published host ports** — only the front is reachable. The "no public IP core" topology holds.
- ✅ Client-server API **and a 10 MB media upload/download round-trip cleanly through the front**, byte-identical. The media path survives the proxy hop.
- ✅ Useful detail: **Caddy has no default request-body limit** (unlike nginx's 1 MB) — media passes with no special config. Production should still set an explicit ceiling = Synapse `max_upload_size`.

## What this does NOT cover (deployment-time checks)

- **WireGuard MSS/PMTU upload-hang** — the real failure mode the SPEC warns about (large uploads black-holing on a misconfigured tunnel) is a _network-layer_ issue a local Docker bridge can't reproduce. Verify on the real front↔core WireGuard link (MSS clamp + `PersistentKeepalive=25`).
- **The MAS `public_base`/cookie gotcha** — already **code-verified** by research (MAS `cookies.rs`: `secure = base_url.scheme() == "https"`, ignoring `X-Forwarded-Proto`). The rule stands: **MAS `http.public_base` MUST be `https://`** or login silently breaks behind a TLS-terminating front. Source is stronger evidence than a black-box curl, so empirical repro was skipped.
- **Full MAS-delegated login end-to-end through the front** — a larger integration test best run once the real MASH stack is stood up (or a dedicated MAS spike).
