/*
 * REDnet in-context invite dialog (soft-fork UI).
 *
 * A quick "vouch someone in" surface for organizers, over the EXISTING mint endpoint
 * (mint_endpoint.py at /governance/mint) — the same one the governance dashboard's Mint tab
 * uses. It POSTs { openid_token, label, format: "plain", count: 1 } (the endpoint authenticates
 * the operator via the Matrix OpenID token in the body and re-checks PL>=75), and shows the
 * returned plain invite (join URL + token) for the organizer to copy and hand off out-of-band.
 *
 * The token reaches only this dialog (never Matrix), exactly like the dashboard flow, and is
 * shown once. The dashboard Mint tab remains the place for batch minting + print-card formats.
 *
 * Self-contained. Copied into src/components/views/dialogs/ by the Dockerfile. Hardcoded English.
 */
import React, { useState } from "react";

import BaseDialog from "./BaseDialog";
import Field from "../elements/Field";
import AccessibleButton from "../elements/AccessibleButton";
import { MatrixClientPeg } from "../../../MatrixClientPeg";

interface IProps {
  onFinished: () => void;
}

export default function RednetInviteDialog({
  onFinished,
}: IProps): JSX.Element {
  const [label, setLabel] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | undefined>();
  const [invite, setInvite] = useState<string | undefined>();
  const [expires, setExpires] = useState<string | undefined>();

  const mint = async (): Promise<void> => {
    const lbl = label.trim();
    if (!lbl) {
      setError("Add a label so you remember who this invite is for.");
      return;
    }
    setBusy(true);
    setError(undefined);
    try {
      const cli = MatrixClientPeg.safeGet();
      const tok = await cli.getOpenIdToken();
      const res = await fetch("/governance/mint", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          openid_token: tok.access_token,
          label: lbl,
          format: "plain",
          count: 1,
        }),
      });
      const data = await res.json().catch(() => ({}));
      setBusy(false);
      if (!res.ok || !data.invites || !data.invites.length) {
        setError(
          res.status === 403
            ? "Only organizers can create invites."
            : "Couldn't create the invite. Try the governance dashboard.",
        );
        return;
      }
      setInvite(data.invites[0].content);
      setExpires(data.invites[0].expires_at);
    } catch {
      setBusy(false);
      setError(
        "Couldn't reach the mint service. Try the governance dashboard.",
      );
    }
  };

  return (
    <BaseDialog title="Invite someone" onFinished={onFinished}>
      {!invite ? (
        <>
          <p style={{ marginTop: 0 }}>
            Create a single-use invite to vouch someone in. Keep the token off
            Matrix — hand it over in person or through a trusted channel.
          </p>
          {error && (
            <p
              style={{
                color: "var(--cpd-color-text-critical-primary, #FF6369)",
                margin: "0 0 12px",
              }}
            >
              {error}
            </p>
          )}
          <Field
            label="Label (who is this for?)"
            value={label}
            onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
              setLabel(e.target.value)
            }
          />
          <AccessibleButton kind="primary" disabled={busy} onClick={mint}>
            {busy ? "Creating…" : "Create invite"}
          </AccessibleButton>
        </>
      ) : (
        <>
          <p style={{ marginTop: 0 }}>
            Invite created{expires ? ` — expires ${expires.slice(0, 10)}` : ""}.
            Copy it now; the token isn&apos;t stored and won&apos;t be shown
            again.
          </p>
          <pre
            style={{
              userSelect: "all",
              whiteSpace: "pre-wrap",
              wordBreak: "break-word",
              background: "rgba(0,0,0,0.25)",
              padding: "12px",
              borderRadius: "8px",
              fontSize: "13px",
              margin: "0 0 14px",
            }}
          >
            {invite}
          </pre>
          <AccessibleButton kind="primary" onClick={onFinished}>
            Done
          </AccessibleButton>
        </>
      )}
    </BaseDialog>
  );
}
