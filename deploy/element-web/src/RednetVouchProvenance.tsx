/*
 * REDnet vouch provenance (soft-fork UI).
 *
 * Surfaces "Vouched by @x" in a member's UserInfo panel — the trust chain, visible where you'd
 * look at someone. The data is the gov-bot's vouch graph: account -> voucher is recorded in
 * `claimed` records (written by `!gov confirm`). We fetch the graph from
 * /governance/data/vouch.jsonl, which the gov-bot now serves behind a valid Matrix OpenID token
 * (mint_endpoint _serve_vouch) — so we send `Authorization: Bearer <openid access_token>` from
 * cli.getOpenIdToken(). Shown to all members (per product decision); best-effort — renders
 * nothing if the fetch fails.
 *
 * Actionable: because `claimed` records are only written by `!gov confirm` (so provenance is
 * often empty), an ORGANIZER (PL>=75 in #governance) viewing an unconfirmed member gets a
 * one-click "Confirm vouch" here that sends `!gov confirm @user` to #gov-bot — the fastest way
 * to fill in the trust chain. The richer form (label + who-vouched) lives in the Manage-member
 * dialog.
 *
 * Self-contained so the UserInfo patch is a one-line insert. Copied into
 * src/components/views/right_panel/ by the Dockerfile. Hardcoded English (the fork ships en only).
 */
import React, { useEffect, useState } from "react";

import AccessibleButton from "../elements/AccessibleButton";
import { MatrixClientPeg } from "../../../MatrixClientPeg";

interface IProps {
  userId: string;
}

// Is the current user an organizer? Members aren't in #governance, so PL>=75 there is the gate
// (same check as RednetGovernanceButton).
function isOrganizer(): boolean {
  const cli = MatrixClientPeg.get();
  const me = cli?.getUserId();
  if (!cli || !me) return false;
  return cli.getRooms().some((r) => {
    const alias = r.getCanonicalAlias();
    if (!alias || !alias.startsWith("#governance:")) return false;
    return (r.getMember(me)?.powerLevel ?? 0) >= 75;
  });
}

async function sendGovConfirm(userId: string): Promise<boolean> {
  const cli = MatrixClientPeg.safeGet();
  const domain = cli.getDomain();
  if (!domain) return false;
  try {
    const res = await cli.getRoomIdForAlias(`#gov-bot:${domain}`);
    const roomId = res?.room_id;
    if (!roomId) return false;
    await cli.sendTextMessage(roomId, `!gov confirm ${userId}`);
    return true;
  } catch {
    return false;
  }
}

export default function RednetVouchProvenance({
  userId,
}: IProps): JSX.Element | null {
  const [voucher, setVoucher] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [confirmState, setConfirmState] = useState<
    "idle" | "sending" | "sent" | "error"
  >("idle");

  useEffect(() => {
    let cancelled = false;
    setVoucher(null);
    setLoaded(false);
    setConfirmState("idle");
    (async (): Promise<void> => {
      try {
        const cli = MatrixClientPeg.safeGet();
        const tok = await cli.getOpenIdToken();
        const res = await fetch("/governance/data/vouch.jsonl", {
          headers: { Authorization: `Bearer ${tok.access_token}` },
          cache: "no-store",
        });
        if (!res.ok) {
          if (!cancelled) setLoaded(true);
          return;
        }
        const text = await res.text();
        let found: string | null = null;
        for (const line of text.split("\n")) {
          const s = line.trim();
          if (!s) continue;
          try {
            const rec = JSON.parse(s);
            if (
              rec.type === "claimed" &&
              rec.account === userId &&
              rec.voucher
            ) {
              found = rec.voucher; // keep scanning — take the most recent claim
            }
          } catch {
            /* skip a malformed line */
          }
        }
        if (!cancelled) {
          setVoucher(found);
          setLoaded(true);
        }
      } catch {
        if (!cancelled) setLoaded(true);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [userId]);

  // Confirmed: show the trust chain to everyone.
  if (voucher) {
    return (
      <div className="mx_UserInfo_profileField">
        <div className="mx_UserInfo_roleDescription">Vouched by {voucher}</div>
      </div>
    );
  }

  // Unconfirmed: only an organizer (not viewing themselves) gets the one-click confirm.
  const cli = MatrixClientPeg.get();
  const isMe = cli?.getUserId() === userId;
  if (!loaded || isMe || !isOrganizer()) return null;

  const onConfirm = async (): Promise<void> => {
    setConfirmState("sending");
    const ok = await sendGovConfirm(userId);
    setConfirmState(ok ? "sent" : "error");
  };

  return (
    <div className="mx_UserInfo_profileField">
      <div
        className="mx_UserInfo_roleDescription"
        style={{
          display: "flex",
          alignItems: "center",
          gap: "8px",
          flexWrap: "wrap",
        }}
      >
        <span style={{ color: "var(--cpd-color-text-secondary, #8B8D98)" }}>
          No vouch recorded
        </span>
        {confirmState === "idle" && (
          <AccessibleButton kind="primary_outline" onClick={onConfirm}>
            Confirm vouch
          </AccessibleButton>
        )}
        {confirmState === "sending" && <span>Confirming…</span>}
        {confirmState === "sent" && (
          <span
            style={{ color: "var(--cpd-color-text-success-primary, #30A46C)" }}
          >
            Confirmed — reopen the profile to see it
          </span>
        )}
        {confirmState === "error" && (
          <span
            style={{ color: "var(--cpd-color-text-critical-primary, #FF6369)" }}
          >
            Couldn&apos;t reach #gov-bot
          </span>
        )}
      </div>
    </div>
  );
}
