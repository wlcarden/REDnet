/*
 * REDnet vouch provenance (soft-fork UI).
 *
 * Surfaces "Vouched by @x" in a member's UserInfo panel — the trust chain, visible where you'd
 * look at someone. The data is the gov-bot's vouch graph: account -> voucher is recorded in
 * `claimed` records (written by `!gov confirm`). We fetch the graph from
 * /governance/data/vouch.jsonl, which the gov-bot now serves behind a valid Matrix OpenID token
 * (mint_endpoint _serve_vouch) — so we send `Authorization: Bearer <openid access_token>` from
 * cli.getOpenIdToken(). Shown to all members (per product decision); best-effort — renders
 * nothing if the fetch fails or no voucher is recorded (many members won't have a `claimed`
 * record).
 *
 * Self-contained so the UserInfo patch is a one-line insert. Copied into
 * src/components/views/right_panel/ by the Dockerfile. Hardcoded English (the fork ships en only).
 */
import React, { useEffect, useState } from "react";

import { MatrixClientPeg } from "../../../MatrixClientPeg";

interface IProps {
  userId: string;
}

export default function RednetVouchProvenance({
  userId,
}: IProps): JSX.Element | null {
  const [voucher, setVoucher] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setVoucher(null);
    (async (): Promise<void> => {
      try {
        const cli = MatrixClientPeg.safeGet();
        const tok = await cli.getOpenIdToken();
        const res = await fetch("/governance/data/vouch.jsonl", {
          headers: { Authorization: `Bearer ${tok.access_token}` },
          cache: "no-store",
        });
        if (!res.ok) return;
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
        if (!cancelled) setVoucher(found);
      } catch {
        /* provenance is best-effort; show nothing on any failure */
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [userId]);

  if (!voucher) return null;
  return (
    <div className="mx_UserInfo_profileField">
      <div className="mx_UserInfo_roleDescription">Vouched by {voucher}</div>
    </div>
  );
}
