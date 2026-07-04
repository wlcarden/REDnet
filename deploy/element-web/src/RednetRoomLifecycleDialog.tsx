/*
 * REDnet room-lifecycle confirm dialog (soft-fork UI).
 *
 * Archive or delete a managed room from the room's right-click menu, running the same governance
 * commands as #gov-bot:
 *   - Archive -> `!gov archive <roomId>`  (organizer; locks read-only + unlinks from its space)
 *   - Delete  -> `!gov delete <roomId>`   (admin; purges the room from the server)
 * Both are destructive, so this is a TYPED confirm — you must type the room's name to enable the
 * button. The command goes to the #gov-bot room, where handle_command enforces the real PL.
 *
 * Self-contained. Copied into src/components/views/dialogs/ by the Dockerfile. Hardcoded English.
 */
import React, { useState } from "react";
import { Room } from "matrix-js-sdk/src/matrix";

import BaseDialog from "./BaseDialog";
import Field from "../elements/Field";
import AccessibleButton from "../elements/AccessibleButton";
import InfoDialog from "./InfoDialog";
import Modal from "../../../Modal";
import { MatrixClientPeg } from "../../../MatrixClientPeg";

interface IProps {
  room: Room;
  action: "archive" | "delete";
  onFinished: (done?: boolean) => void;
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

export default function RednetRoomLifecycleDialog({
  room,
  action,
  onFinished,
}: IProps): JSX.Element {
  const [typed, setTyped] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | undefined>();

  const isDelete = action === "delete";
  const roomName = room.name || room.getCanonicalAlias() || room.roomId;
  const match = typed.trim() === roomName;

  const go = async (): Promise<void> => {
    if (!match) return;
    setBusy(true);
    setError(undefined);
    const ok = await sendGovCommand(`!gov ${action} ${room.roomId}`);
    setBusy(false);
    if (!ok) {
      setError(
        `Couldn't reach #gov-bot. Run \`!gov ${action}\` there instead.`,
      );
      return;
    }
    onFinished(true);
    Modal.createDialog(InfoDialog, {
      title: isDelete ? "Delete requested" : "Archive requested",
      description: `Sent \`!gov ${action}\` for ${roomName} to #gov-bot.${
        isDelete ? " Admin PL is required." : ""
      } Check there for the result.`,
      hasCloseButton: true,
    });
  };

  return (
    <BaseDialog
      title={isDelete ? "Delete room" : "Archive room"}
      onFinished={() => onFinished(false)}
    >
      <p>
        {isDelete ? (
          <>
            This purges <strong>{roomName}</strong> from the server. It
            can&apos;t be undone.
          </>
        ) : (
          <>
            This locks <strong>{roomName}</strong> read-only and unlinks it from
            its space. Members keep their history but can&apos;t post.
          </>
        )}
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
        label={`Type the room name to confirm: ${roomName}`}
        value={typed}
        onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
          setTyped(e.target.value)
        }
      />
      <AccessibleButton kind="danger" disabled={!match || busy} onClick={go}>
        {busy ? "Working…" : isDelete ? "Delete room" : "Archive room"}
      </AccessibleButton>
    </BaseDialog>
  );
}
