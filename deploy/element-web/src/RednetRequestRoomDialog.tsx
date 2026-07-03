/*
 * REDnet "Request a room or space" dialog (soft-fork UI).
 *
 * Native room/space creation is locked server-side (synapse-modules/rednet_room_policy)
 * and its buttons are hidden (RednetComponentVisibility). This is the POSITIVE affordance
 * that replaces them: a member fills in a name + reason, and we send the governance
 * command `!gov request room|space "NAME" --why "REASON"` to their DM with @rednet-gov
 * (the gov bot's handle_dm_gov turns it into an organizer-reviewed request). The token
 * never leaves the member's own client; nothing is created here — it's a request.
 *
 * Self-contained so the RoomListHeader patch is a one-line menu item. Copied into
 * src/components/views/dialogs/ by the Dockerfile. Hardcoded English (fork ships en only),
 * which also sidesteps Element's compile-time _t() key gating.
 */
import React, { useState } from "react";

import BaseDialog from "./BaseDialog";
import DialogButtons from "../elements/DialogButtons";
import Field from "../elements/Field";
import InfoDialog from "./InfoDialog";
import Modal from "../../../Modal";
import { MatrixClientPeg } from "../../../MatrixClientPeg";
import { ensureDMExists } from "../../../createRoom";

interface IProps {
  onFinished: (sent?: boolean) => void;
}

type RequestType = "room" | "space";

export default function RednetRequestRoomDialog({
  onFinished,
}: IProps): JSX.Element {
  const [type, setType] = useState<RequestType>("room");
  const [name, setName] = useState("");
  const [why, setWhy] = useState("");
  const [error, setError] = useState<string | undefined>();
  const [busy, setBusy] = useState(false);

  const submit = async (): Promise<void> => {
    const cleanName = name.trim();
    if (!cleanName) {
      setError("Give it a name so organizers know what you're asking for.");
      return;
    }
    const cli = MatrixClientPeg.safeGet();
    const domain = cli.getDomain();
    if (!domain) {
      setError("Still connecting — try again in a moment.");
      return;
    }
    const govMxid = `@rednet-gov:${domain}`;
    const cleanWhy = why.trim();
    // Quote-escape so a name/reason with a " can't break the command parse.
    const q = (s: string): string => s.replace(/"/g, "'");
    const body =
      `!gov request ${type} "${q(cleanName)}"` +
      (cleanWhy ? ` --why "${q(cleanWhy)}"` : "");

    setBusy(true);
    setError(undefined);
    try {
      const roomId = await ensureDMExists(cli, govMxid);
      if (!roomId) throw new Error("could not open the gov-bot DM");
      await cli.sendTextMessage(roomId, body);
      onFinished(true);
      Modal.createDialog(InfoDialog, {
        title: "Request sent",
        description:
          "An organizer will follow up in your chat with @rednet-gov. Open that " +
          "conversation to see their reply — if it's approved you'll be invited automatically.",
        hasCloseButton: true,
      });
    } catch {
      setBusy(false);
      setError(
        "Couldn't send the request. Open your chat with @rednet-gov and send it there, or try again.",
      );
    }
  };

  return (
    <BaseDialog
      title="Request a room or space"
      onFinished={() => onFinished(false)}
    >
      <p>
        Rooms and spaces are set up encrypted and connected to the community by
        an organizer — there's no create button. Tell them what you need and it
        goes to their review queue. Your request is private; other members don't
        see it.
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
        label="What do you need?"
        value={type}
        onChange={(e: React.ChangeEvent<HTMLSelectElement>) =>
          setType(e.target.value as RequestType)
        }
      >
        <option value="room">A room — a single channel</option>
        <option value="space">
          A space — a folder that groups several rooms
        </option>
      </Field>
      <Field
        type="text"
        label="Name"
        value={name}
        autoComplete="off"
        placeholder={
          type === "space" ? "e.g. Northwest Chapter" : "e.g. Kitchen Crew"
        }
        onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
          setName(e.target.value)
        }
      />
      <Field
        element="textarea"
        label="Why? (optional — helps organizers decide)"
        value={why}
        onChange={(e: React.ChangeEvent<HTMLTextAreaElement>) =>
          setWhy(e.target.value)
        }
      />
      <DialogButtons
        primaryButton={busy ? "Sending…" : "Send request"}
        primaryDisabled={busy}
        onPrimaryButtonClick={submit}
        onCancel={() => onFinished(false)}
      />
    </BaseDialog>
  );
}
