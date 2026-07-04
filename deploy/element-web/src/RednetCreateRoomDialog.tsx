/*
 * REDnet "Create room or space" dialog (soft-fork UI).
 *
 * Organizer-only. Native room creation is server-locked (rooms are born through the gov bot), and
 * the member-facing "Request a room" button only FILES a request that an organizer then approves.
 * This is the missing inverse: an organizer creating a room/space DIRECTLY, without the request
 * round-trip. It sends the same `!gov room` / `!gov space` command an organizer would type, to the
 * #gov-bot room (handle_command enforces PL and does the work: encrypted room, linked into the
 * space, logged to the audit trail).
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
  onFinished: (created?: boolean) => void;
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

export default function RednetCreateRoomDialog({
  onFinished,
}: IProps): JSX.Element {
  const [kind, setKind] = useState("room");
  const [name, setName] = useState("");
  const [visibility, setVisibility] = useState("knock");
  const [unlisted, setUnlisted] = useState(false);
  const [parent, setParent] = useState("");
  const [topic, setTopic] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | undefined>();

  const isRoom = kind === "room";
  // Quote-escape so a name/topic with a " can't break the command parse.
  const q = (s: string): string => s.replace(/"/g, "'");

  const submit = async (): Promise<void> => {
    const cleanName = name.trim();
    if (!cleanName) {
      setError("Give it a name.");
      return;
    }
    const parts = [`!gov ${kind} "${q(cleanName)}"`];
    if (isRoom && visibility !== "knock")
      parts.push(`--visibility ${visibility}`);
    if (isRoom && visibility === "private" && unlisted)
      parts.push("--unlisted");
    if (parent.trim()) parts.push(`--space ${parent.trim()}`);
    if (isRoom && topic.trim()) parts.push(`--topic "${q(topic.trim())}"`);

    setBusy(true);
    setError(undefined);
    const ok = await sendGovCommand(parts.join(" "));
    setBusy(false);
    if (!ok) {
      setError(`Couldn't reach #gov-bot. Run \`!gov ${kind}\` there instead.`);
      return;
    }
    onFinished(true);
    Modal.createDialog(InfoDialog, {
      title: isRoom ? "Creating room" : "Creating space",
      description: `Sent \`!gov ${kind} "${cleanName}"\` to #gov-bot — it'll appear in your list once the bot finishes creating it (check #gov-bot for the result).`,
      hasCloseButton: true,
    });
  };

  return (
    <BaseDialog
      title="Create a room or space"
      onFinished={() => onFinished(false)}
    >
      <p style={{ marginTop: 0 }}>
        As an organizer you can create these directly — no request needed. Rooms
        are always encrypted and linked into the space.
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
        label="What to create"
        value={kind}
        onChange={(e: React.ChangeEvent<HTMLSelectElement>) =>
          setKind(e.target.value)
        }
      >
        <option value="room">Room</option>
        <option value="space">Space (a folder that groups rooms)</option>
      </Field>
      <Field
        label="Name"
        value={name}
        onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
          setName(e.target.value)
        }
      />
      {isRoom && (
        <Field
          element="select"
          label="Who can join"
          value={visibility}
          onChange={(e: React.ChangeEvent<HTMLSelectElement>) =>
            setVisibility(e.target.value)
          }
        >
          <option value="knock">Knock — visible, ask to join (default)</option>
          <option value="open">
            Open — any member of the parent space joins
          </option>
          <option value="private">Private — invite-only</option>
        </Field>
      )}
      {isRoom && visibility === "private" && (
        <label
          style={{
            display: "flex",
            gap: "8px",
            alignItems: "center",
            margin: "8px 0",
            fontSize: "14px",
          }}
        >
          <input
            type="checkbox"
            checked={unlisted}
            onChange={(e) => setUnlisted(e.target.checked)}
            style={{ accentColor: "#E5484D" }}
          />
          Unlisted — hide even the room's name from non-members
        </label>
      )}
      <Field
        label="Parent space slug (optional)"
        value={parent}
        onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
          setParent(e.target.value)
        }
      />
      {isRoom && (
        <Field
          label="Topic (optional)"
          value={topic}
          onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
            setTopic(e.target.value)
          }
        />
      )}
      <DialogButtons
        primaryButton={busy ? "Creating…" : `Create ${kind}`}
        primaryDisabled={busy}
        onPrimaryButtonClick={submit}
        onCancel={() => onFinished(false)}
      />
    </BaseDialog>
  );
}
