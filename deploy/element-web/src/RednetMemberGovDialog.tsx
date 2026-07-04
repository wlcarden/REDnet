/*
 * REDnet "Manage member" governance dialog (soft-fork UI).
 *
 * Organizer-only member actions surfaced from the UserInfo panel (the button that opens this
 * is PL>=75-gated). It runs the SAME governance commands an organizer would type in #gov-bot,
 * just from a right-click:
 *   - Set role   -> `!gov role @user moderator|organizer`
 *   - Revoke     -> `!gov revoke @user --reason "..."`
 * Both are sent to the #gov-bot room (where the organizer is a member and handle_command
 * enforces the real PL authorization + writes the audit record). Nothing is authorized
 * client-side — this is a convenience surface over the existing chat commands.
 *
 * Self-contained so the UserInfo patch is a one-line menu item. Copied into
 * src/components/views/dialogs/ by the Dockerfile. Hardcoded English (the fork ships en only).
 */
import React, { useState } from "react";
import { RoomMember } from "matrix-js-sdk/src/matrix";

import BaseDialog from "./BaseDialog";
import Field from "../elements/Field";
import AccessibleButton from "../elements/AccessibleButton";
import InfoDialog from "./InfoDialog";
import Modal from "../../../Modal";
import { MatrixClientPeg } from "../../../MatrixClientPeg";

interface IProps {
  member: RoomMember;
  onFinished: (done?: boolean) => void;
}

// Send a `!gov` command to the #gov-bot room (resolved by alias — the organizer is a
// member there). Returns false if the room can't be reached, so the caller can fall back
// to telling the organizer to run it by hand.
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

export default function RednetMemberGovDialog({
  member,
  onFinished,
}: IProps): JSX.Element {
  const [role, setRole] = useState("moderator");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | undefined>();
  const [busy, setBusy] = useState(false);
  const target = member.userId;

  // Quote-escape so a reason with a " can't break the command parse.
  const q = (s: string): string => s.replace(/"/g, "'");

  const applyRole = async (): Promise<void> => {
    setBusy(true);
    setError(undefined);
    const ok = await sendGovCommand(`!gov role ${target} ${role}`);
    setBusy(false);
    if (!ok) {
      setError("Couldn't reach #gov-bot. Run `!gov role` there instead.");
      return;
    }
    onFinished(true);
    Modal.createDialog(InfoDialog, {
      title: "Role change requested",
      description: `Sent \`!gov role ${target} ${role}\` to #gov-bot — check there for the result and the audit record.`,
      hasCloseButton: true,
    });
  };

  const revoke = async (): Promise<void> => {
    const cleanReason = reason.trim();
    if (!cleanReason) {
      setError("A revoke needs a reason — it's recorded in the audit log.");
      return;
    }
    setBusy(true);
    setError(undefined);
    const ok = await sendGovCommand(
      `!gov revoke ${target} --reason "${q(cleanReason)}"`,
    );
    setBusy(false);
    if (!ok) {
      setError("Couldn't reach #gov-bot. Run `!gov revoke` there instead.");
      return;
    }
    onFinished(true);
    Modal.createDialog(InfoDialog, {
      title: "Revoke requested",
      description: `Sent \`!gov revoke\` for ${target} to #gov-bot. Admin PL is required — check there for the result.`,
      hasCloseButton: true,
    });
  };

  return (
    <BaseDialog title="Manage member" onFinished={() => onFinished(false)}>
      <p>
        Governance actions for <strong>{target}</strong>. These run the same{" "}
        <code>!gov</code> commands as #gov-bot, where the result and the audit
        record appear.
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
        element="select"
        label="Set role"
        value={role}
        onChange={(e: React.ChangeEvent<HTMLSelectElement>) =>
          setRole(e.target.value)
        }
      >
        <option value="moderator">Moderator</option>
        <option value="organizer">Organizer (requires admin)</option>
      </Field>
      <AccessibleButton kind="primary" onClick={applyRole} disabled={busy}>
        {busy ? "Working…" : "Apply role"}
      </AccessibleButton>

      <div
        style={{
          height: "1px",
          background: "rgba(255,255,255,0.08)",
          margin: "18px 0",
        }}
      />

      <Field
        element="textarea"
        label="Revoke access — reason (recorded in the audit log)"
        value={reason}
        onChange={(e: React.ChangeEvent<HTMLTextAreaElement>) =>
          setReason(e.target.value)
        }
      />
      <AccessibleButton kind="danger" onClick={revoke} disabled={busy}>
        {busy ? "Working…" : "Revoke access"}
      </AccessibleButton>
    </BaseDialog>
  );
}
