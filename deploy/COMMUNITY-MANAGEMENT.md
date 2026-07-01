# Community Management — room/space governance

How organizers create, share, and retire rooms and spaces — and why members can't
do it directly. Companion to DESIGN.md §11 (Governance). Decisions recorded
2026-07-01.

## The problem

Vanilla Matrix lets every authenticated user create rooms and spaces. On this
stack that meant:

- Members could create **unencrypted** rooms and chat in them (server-side
  E2EE-by-default is deliberately off — it breaks the plaintext bot rooms, see
  setup.sh's `encryption_enabled_by_default_for_room_type` comment).
- Rooms created outside the space hierarchy were invisible to organizers — no
  audit trail, no retention conventions, no oversight.
- Anyone could alias-squat a lookalike (`#general2`) for phishing.

## The model

**Creation is locked to the system accounts. Everything else flows through the
gov bot.** Day-to-day management _inside_ existing rooms (topics, pins, kicks,
knock approvals) stays native Element UX for room moderators — the lockdown
gates creation only.

### Enforcement (layered)

1. **Synapse module** (`synapse-modules/rednet_room_policy.py`, wired by
   setup.sh): the `on_create_room` third-party-rules callback allows
   `rednet-system`, `rednet-gov`, `rednet-mod`, permits DM-shaped requests from
   anyone (`is_direct`, no alias, ≤1 invite, private preset), and denies
   everything else by raising a `SynapseError` whose message tells the member to
   use `!gov request`.
2. **`alias_creation_rules`** (vanilla config): only the system accounts may
   attach aliases. Blocks alias squatting even if the module fails to load.
3. **`room_list_publication_rules`**: nobody publishes to the room directory;
   the space hierarchy IS the directory.
4. **Audit sweep** (`!gov audit` + verify-hardening.sh): every swept room must
   be E2EE unless allowlisted plaintext (`#gov-bot`, Draupnir rooms); flags
   rooms outside the hierarchy and "DMs" that grew past 2 members.

**Residual risk (accepted):** the DM carve-out is policy, not cryptography. A
custom (non-Element) client can shape a createRoom request like a DM and get a
1:1 room through. It cannot attach an alias, and the sweep flags growth. A
coerced insider could always fall back to Signal; this bounds what the _server_
legitimizes, it does not pretend to stop out-of-band coordination.

### Synapse admin scope (delete + sweep)

`!gov delete` (purge API) and the `!gov audit` room sweep (list-all-rooms API)
need `/_synapse/admin`. Under MAS delegation that is **not** a row in Synapse's
`users` table — it's the `urn:synapse:admin:*` OAuth scope on the bot's token.
bootstrap-gov-bot.sh sets this up in two steps: `mas-cli manage promote-admin
rednet-system` (makes the account admin-capable) and issuing the bot's
`SYS_TOKEN` with `--yes-i-want-to-grant-synapse-admin-privileges` (mints a token
that carries the scope). A direct `UPDATE users SET admin=1` does nothing here —
MAS owns that state. The FRONT Caddy also blocks `/_synapse/admin` from the
public edge (defense in depth); the bot reaches it over the internal
`synapse:8008`, never through Caddy. If the token lacks the scope, both commands
fail closed with a "not a server admin" message and the sweep degrades to a
visible `SWEEP SKIPPED` audit alert.

### Visibility tiers (creator picks one; all rooms E2EE, all audited)

| Tier                  | join_rule                          | In hierarchy?                                                   | Meaning                                                                                                                  |
| --------------------- | ---------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `open`                | `restricted` (allow: parent space) | yes                                                             | any member of the parent space browses + joins freely                                                                    |
| `knock` **(default)** | `knock`                            | yes                                                             | visible; "Ask to join" (Element `feature_ask_to_join` is already enabled); a room moderator approves                     |
| `private`             | `invite`                           | optional — `--unlisted` omits the `m.space.child` link entirely | invite-only; unlisted rooms don't even leak their **name** (space children are readable by everyone in the parent space) |

The default is knock: a forgotten flag on a sensitive room fails closed.
`restricted` is scoped, not global — "open" can mean open-to-community or
open-to-one-compartment depending on the parent space. Matrix `public` join
rule is never used (on a closed island it duplicates `restricted` with less
control). Room version 12 (our default) supports both `knock` and `restricted`.

### Command surface

| Command                                                                              | PL  | Where           | Does                                                                                                                    |
| ------------------------------------------------------------------------------------ | --- | --------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `!gov request room\|space <name> --why <reason>`                                     | 0   | member's bot DM | queue a creation request; private — other members never see it                                                          |
| `!gov requests`                                                                      | 75  | #gov-bot        | list pending requests                                                                                                   |
| `!gov approve <id> [--visibility ...] [--space <slug>]`                              | 75  | #gov-bot        | create + link + invite requester; **requester gets PL50** in the new room                                               |
| `!gov deny <id> <reason>`                                                            | 75  | #gov-bot        | decline; bot DMs the requester the reason                                                                               |
| `!gov space <name>`                                                                  | 75  | #gov-bot        | create a sub-space in the hierarchy                                                                                     |
| `!gov room <name> [--visibility open\|knock\|private] [--space <slug>] [--unlisted]` | 75  | #gov-bot        | direct creation, no request needed                                                                                      |
| `!gov invite <user> <room>`                                                          | 75  | #gov-bot        | invite a member to any managed room                                                                                     |
| `!gov rooms`                                                                         | 75  | #gov-bot        | full inventory incl. unlisted rooms (from the bot's index)                                                              |
| `!gov members <room>`                                                                | 75  | #gov-bot        | membership of any managed room                                                                                          |
| `!gov archive <room>`                                                                | 75  | #gov-bot        | unlink from hierarchy + lock read-only (`events_default: 100`), no new joins; history remains until retention purges it |
| `!gov delete <room>`                                                                 | 100 | #gov-bot        | Synapse admin purge — content actually removed from the server                                                          |

Requester-as-moderator is the point of the request flow: organizers approve
once, then the person who wanted the room runs it (knocks, invites, pins).

### Request flow

Members are **not** in `#gov-bot` (it lives in the Organizing sub-space). The
flow crosses that boundary through the bot:

1. Member, in their existing bot DM: `!gov request room "Kitchen Crew" --why "coordinate food runs"`
2. Bot appends `{type:"room-request", id, requester, kind, name, why, ts}` to
   `vouch.jsonl` and posts `REQ-xxxx` into `#gov-bot`.
3. Organizer: `!gov approve REQ-xxxx` (flags optional) or `!gov deny REQ-xxxx <reason>`.
4. Bot appends `{type:"room-request-decision", id, decision, by, ts}`
   (append-only — decisions are new records, never mutations), creates the room
   on approve, invites the requester at PL50, and DMs them the outcome either way.

All audit records land in `vouch.jsonl` (the canonical trail) plus a visible
confirmation in `#gov-bot`. The bot never posts to `#vouch-log` — that room is
E2EE and the bot cannot encrypt for it.

### Why E2EE stays per-creation, not server-default

`encryption_enabled_by_default_for_room_type: all` force-encrypts every new
room including the plaintext bot rooms — that's why setup.sh turned it off.
Under the lockdown the bot is the only creator of shared rooms, so its
hardcoded megolm `initial_state` (no flag to disable) IS the server-level
guarantee, with the audit sweep as the independent second layer. This also
covers rooms that predate any config change, which the server default never
did.

## Escalation path unchanged

Revocation, role assignment, and the vouch system are untouched. `archive` is
PL75 because it's reversible in spirit (nothing is destroyed); `delete` is
PL100 because purge is forensic-relevant — on seizure, an archived room is
evidence, a purged one is not (client-side copies notwithstanding).
