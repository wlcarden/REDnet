/*
 * REDnet "Pending requests" dialog (soft-fork UI).
 *
 * Closes the asymmetry where members request rooms/spaces through a polished dialog
 * (RednetRequestRoomDialog) but organizers have to notice the request in chat and type
 * `!gov approve`/`!gov deny`. Organizer-only.
 *
 * Data: reads the gov-bot vouch graph from /governance/data/vouch.jsonl (served behind a Matrix
 * OpenID token since Wave 4) and mirrors the gov-bot's own pending() logic — `room-request`
 * records minus any `room-request-decision` with the same id. Actions send `!gov approve <id>`
 * / `!gov deny <id> <reason>` to the #gov-bot room (handle_command enforces PL + does the work).
 *
 * Self-contained. Copied into src/components/views/dialogs/ by the Dockerfile. Hardcoded English.
 */
import React, { useEffect, useState } from "react";

import BaseDialog from "./BaseDialog";
import Field from "../elements/Field";
import AccessibleButton from "../elements/AccessibleButton";
import { MatrixClientPeg } from "../../../MatrixClientPeg";

interface Req {
  id: string;
  requester: string;
  kind: string;
  name: string;
  why: string;
}

interface IProps {
  onFinished: () => void;
}

async function sendGovCommand(body: string): Promise<boolean> {
  const cli = MatrixClientPeg.safeGet();
  const domain = cli.getDomain();
  if (!domain) return false;
  try {
    const res = await cli.getRoomIdForAlias(`#gov-bot:${domain}`);
    const roomId = res?.room_id;
    if (!roomId) return false;
    await cli.sendTextMessage(roomId, body);
    return true;
  } catch {
    return false;
  }
}

export default function RednetRequestsDialog({
  onFinished,
}: IProps): JSX.Element {
  const [reqs, setReqs] = useState<Req[] | null>(null); // null = loading
  const [failed, setFailed] = useState(false);
  const [act, setAct] = useState<Record<string, string>>({});
  const [reason, setReason] = useState<Record<string, string>>({});

  useEffect(() => {
    let cancelled = false;
    (async (): Promise<void> => {
      try {
        const cli = MatrixClientPeg.safeGet();
        const tok = await cli.getOpenIdToken();
        const res = await fetch("/governance/data/vouch.jsonl", {
          headers: { Authorization: `Bearer ${tok.access_token}` },
          cache: "no-store",
        });
        if (!res.ok) {
          if (!cancelled) setFailed(true);
          return;
        }
        const text = await res.text();
        const requests: Req[] = [];
        const decided = new Set<string>();
        for (const line of text.split("\n")) {
          const s = line.trim();
          if (!s) continue;
          try {
            const rec = JSON.parse(s);
            if (rec.type === "room-request" && rec.id) {
              requests.push({
                id: rec.id,
                requester: rec.requester || "(unknown)",
                kind: rec.kind || "room",
                name: rec.name || "",
                why: rec.why || "",
              });
            } else if (rec.type === "room-request-decision" && rec.id) {
              decided.add(rec.id);
            }
          } catch {
            /* skip a malformed line */
          }
        }
        if (!cancelled) setReqs(requests.filter((r) => !decided.has(r.id)));
      } catch {
        if (!cancelled) setFailed(true);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const approve = async (id: string): Promise<void> => {
    setAct((a) => ({ ...a, [id]: "working" }));
    const ok = await sendGovCommand(`!gov approve ${id}`);
    setAct((a) => ({ ...a, [id]: ok ? "approved" : "error" }));
  };

  const confirmDeny = async (id: string): Promise<void> => {
    const r = (reason[id] || "").trim().replace(/\s+/g, " ");
    if (!r) return;
    setAct((a) => ({ ...a, [id]: "working" }));
    const ok = await sendGovCommand(`!gov deny ${id} ${r}`);
    setAct((a) => ({ ...a, [id]: ok ? "denied" : "error" }));
  };

  const rowStyle: React.CSSProperties = {
    border: "1px solid rgba(255,255,255,0.08)",
    borderRadius: "10px",
    padding: "12px 14px",
    marginBottom: "10px",
  };
  const muted = { color: "var(--cpd-color-text-secondary, #8B8D98)" };

  let body: JSX.Element;
  if (failed) {
    body = (
      <p style={muted}>
        Couldn&apos;t load requests — you may not be an organizer, or #gov-bot
        is unreachable.
      </p>
    );
  } else if (reqs === null) {
    body = <p style={muted}>Loading…</p>;
  } else if (reqs.length === 0) {
    body = <p style={muted}>No pending requests.</p>;
  } else {
    body = (
      <div>
        {reqs.map((req) => {
          const st = act[req.id] || "idle";
          if (st === "approved" || st === "denied") {
            return (
              <div key={req.id} style={rowStyle}>
                <strong>{req.id}</strong>{" "}
                <span
                  style={{
                    color:
                      st === "approved"
                        ? "var(--cpd-color-text-success-primary, #30A46C)"
                        : "var(--cpd-color-text-secondary, #8B8D98)",
                  }}
                >
                  {st === "approved" ? "Approved" : "Denied"}
                </span>
              </div>
            );
          }
          return (
            <div key={req.id} style={rowStyle}>
              <div style={{ marginBottom: "4px" }}>
                <strong>{req.id}</strong> — {req.requester} requests {req.kind}{" "}
                <strong>{req.name}</strong>
              </div>
              {req.why && (
                <div style={{ ...muted, marginBottom: "8px" }}>
                  Why: {req.why}
                </div>
              )}
              {st === "denying" ? (
                <div>
                  <Field
                    element="textarea"
                    label="Reason (sent to the requester)"
                    value={reason[req.id] || ""}
                    onChange={(e: React.ChangeEvent<HTMLTextAreaElement>) =>
                      setReason((m) => ({ ...m, [req.id]: e.target.value }))
                    }
                  />
                  <div style={{ display: "flex", gap: "8px" }}>
                    <AccessibleButton
                      kind="danger"
                      disabled={!(reason[req.id] || "").trim()}
                      onClick={() => confirmDeny(req.id)}
                    >
                      Confirm deny
                    </AccessibleButton>
                    <AccessibleButton
                      kind="link"
                      onClick={() =>
                        setAct((a) => ({ ...a, [req.id]: "idle" }))
                      }
                    >
                      Cancel
                    </AccessibleButton>
                  </div>
                </div>
              ) : (
                <div
                  style={{ display: "flex", gap: "8px", alignItems: "center" }}
                >
                  <AccessibleButton
                    kind="primary"
                    disabled={st === "working"}
                    onClick={() => approve(req.id)}
                  >
                    {st === "working" ? "Working…" : "Approve"}
                  </AccessibleButton>
                  <AccessibleButton
                    kind="danger_outline"
                    disabled={st === "working"}
                    onClick={() =>
                      setAct((a) => ({ ...a, [req.id]: "denying" }))
                    }
                  >
                    Deny
                  </AccessibleButton>
                  {st === "error" && (
                    <span
                      style={{
                        color:
                          "var(--cpd-color-text-critical-primary, #FF6369)",
                      }}
                    >
                      Couldn&apos;t reach #gov-bot
                    </span>
                  )}
                </div>
              )}
            </div>
          );
        })}
      </div>
    );
  }

  return (
    <BaseDialog title="Pending requests" onFinished={onFinished}>
      <p style={{ marginTop: 0 }}>
        Room and space requests from members. Approving creates the room and
        makes the requester its moderator; both run the same <code>!gov</code>{" "}
        commands as #gov-bot.
      </p>
      {body}
    </BaseDialog>
  );
}
