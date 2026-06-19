# REDnet spikes

Each spike is a **self-contained, runnable harness** with a hard PASS/FAIL, turning `SPEC.md §13` from vague TODOs into executable verification. Run from each spike's directory: `bash run.sh`.

| #   | Spike                                                                   | Runnable here?                        | Status      |
| --- | ----------------------------------------------------------------------- | ------------------------------------- | ----------- |
| 01  | Retention **purges encrypted-room** message events (gating)             | ✅ Docker                             | ✅ **PASS** |
| 03  | Two-tier: media through the proxy + the MAS `public_base`/cookie gotcha | ✅ Docker (proxy hop approximates WG) | ✅ **PASS** |
| 04  | Backup → cold restore → encrypted-message smoke test                    | ✅ Docker                             | ✅ **PASS** |
| 05  | Recovery-key escrow crypto (ECIES + Shamir + P-256)                     | ✅ pure crypto (`uv`)                 | ✅ **PASS** |
| 06  | Moderator keys on P-256 secure elements                                 | ✅ pure crypto (`uv`)                 | ✅ **PASS** |
| 07  | Matrix-native escrow store + producer round-trip                        | ✅ Docker (self-contained Synapse)    | ✅ **PASS** |
| 08  | Quorum growth (M/N scales with the community)                           | ✅ pure crypto (`uv`)                 | ✅ **PASS** |
| 09  | Escrow-record authentication (closes security-review HIGH)              | ✅ pure crypto (`uv`)                 | ✅ **PASS** |
| —   | **test-vectors/** — cross-language ECIES/HKDF/AES-GCM oracle            | ✅ Node 18+ (`node test-vectors.mjs`) | ✅ **PASS** |

The onboarding prototype lives in `prototype/onboarding*/` (not a numbered spike) — milestones A+B+D verified, browser E2E proven (2/2 PASS, 2026-06-19).

Requirements: Docker + Docker Compose (for infra spikes), or `uv` (for pure-crypto spikes), internet (image pulls). Each harness stands up the minimum stack, runs the test, prints a verdict, and tears down. Nothing here is production config — these prove specific behaviors.
