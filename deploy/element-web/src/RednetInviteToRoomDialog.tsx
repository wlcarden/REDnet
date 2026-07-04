/*
 * REDnet "Add a member to a room" dialog (soft-fork UI).
 *
 * Organizer-only. Native Element invite works when you're already a member of the target room;
 * this covers the gov-bot's `!gov invite @user room-alias`, which uses the bot to invite an
 * existing member into ANY managed room (even one you're not in). Sends the command to #gov-bot.
 *
 * Self-contained; opened from the Governance menu. Copied into src/components/views/dialogs/ by
 * the Dockerfile. Hardcoded English (the fork ships en only).
 */
import React, { useState } from "react";

import BaseDialog from "./BaseDialog";
import Field from "../elements/Field";
import DialogButtons from "../elements/DialogButtons";
import InfoDialog from "./InfoDialog";
import Modal from "../../../Modal";
import { MatrixClientPeg } from "../../../MatrixClientPeg";

interface IProps {
  onFinished: (sent?: boolean) => void;
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

export default function RednetInviteToRoomDialog({
  onFinished,
}: IProps): JSX.Element {
  const [user, setUser] = useState("");
  const [room, setRoom] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | undefined>();

  const submit = async (): Promise<void> => {
    const u = user.trim();
    const r = room.trim().replace(/^#/, "");
    if (!u.startsWith("@") || !u.includes(":")) {
      setError("Enter a full user id, like @maria:example.org.");
      return;
    }
    if (!r) {
      setError("Enter the room's alias (its short name).");
      return;
    }
    setBusy(true);
    setError(undefined);
    const ok = await sendGovCommand(`!gov invite ${u} ${r}`);
    setBusy(false);
    if (!ok) {
      setError("Couldn't reach #gov-bot. Run `!gov invite` there instead.");
      return;
    }
    onFinished(true);
    Modal.createDialog(InfoDialog, {
      title: "Invite sent",
      description: `Sent \`!gov invite ${u} ${r}\` to #gov-bot — check there for the result.`,
      hasCloseButton: true,
    });
  };

  return (
    <BaseDialog
      title="Add a member to a room"
      onFinished={() => onFinished(false)}
    >
      <p style={{ marginTop: 0 }}>
        Invite an existing member into a managed room through the gov bot
        &mdash; useful for a room you're not in yourself. To invite people to a
        room you're already in, use the room's own <strong>Invite</strong>{" "}
        instead.
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
        label="Member (their full user id)"
        value={user}
        onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
          setUser(e.target.value)
        }
      />
      <Field
        label="Room alias (its short name, e.g. kitchen-crew)"
        value={room}
        onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
          setRoom(e.target.value)
        }
      />
      <DialogButtons
        primaryButton={busy ? "Sending…" : "Send invite"}
        primaryDisabled={busy}
        onPrimaryButtonClick={submit}
        onCancel={() => onFinished(false)}
      />
    </BaseDialog>
  );
}
