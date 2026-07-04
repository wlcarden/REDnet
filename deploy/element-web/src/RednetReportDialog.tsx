/*
 * REDnet "Report to organizers" dialog (soft-fork UI).
 *
 * The native message Report was removed (hide-affordances.patch) because it POSTs the event +
 * reason to the HOMESERVER ADMIN — the party our threat model distrusts. This is its
 * replacement: a member reports a message to the community's own organizers via the
 * coercion-aware `!report` flow. We send `!report @sender --detail "<reason> [message <id> in
 * <room>]"` to the member's DM with @rednet-gov (the gov bot's handle_report alerts organizers
 * in #gov-bot and records it). The report is private — the reported user is never notified.
 *
 * Self-contained so the MessageContextMenu patch is a one-line menu item. Copied into
 * src/components/views/dialogs/ by the Dockerfile. Hardcoded English (the fork ships en only),
 * which also sidesteps Element's compile-time _t() key gating.
 */
import React, { useState } from "react";
import { MatrixEvent } from "matrix-js-sdk/src/matrix";

import BaseDialog from "./BaseDialog";
import DialogButtons from "../elements/DialogButtons";
import Field from "../elements/Field";
import InfoDialog from "./InfoDialog";
import Modal from "../../../Modal";
import { MatrixClientPeg } from "../../../MatrixClientPeg";
import { ensureDMExists } from "../../../createRoom";

interface IProps {
  mxEvent: MatrixEvent;
  onFinished: (sent?: boolean) => void;
}

export default function RednetReportDialog({
  mxEvent,
  onFinished,
}: IProps): JSX.Element {
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | undefined>();
  const [busy, setBusy] = useState(false);

  const sender = mxEvent.getSender() || "(unknown)";

  const submit = async (): Promise<void> => {
    const cleanReason = reason.trim();
    if (!cleanReason) {
      setError("Add a short note so organizers know what's wrong.");
      return;
    }
    const cli = MatrixClientPeg.safeGet();
    const domain = cli.getDomain();
    if (!domain) {
      setError("Still connecting - try again in a moment.");
      return;
    }
    const govMxid = `@rednet-gov:${domain}`;
    // Quote-escape so a reason with a " can't break the command parse.
    const q = (s: string): string => s.replace(/"/g, "'");
    const eventId = mxEvent.getId() || "";
    const roomId = mxEvent.getRoomId() || "";
    const detail = `${q(cleanReason)} [message ${eventId} in ${roomId}]`;
    const body = `!report ${sender} --detail "${detail}"`;

    setBusy(true);
    setError(undefined);
    try {
      const dm = await ensureDMExists(cli, govMxid);
      if (!dm) throw new Error("could not open the gov-bot DM");
      await cli.sendTextMessage(dm, body);
      onFinished(true);
      Modal.createDialog(InfoDialog, {
        title: "Reported to organizers",
        description:
          "Organizers have been notified in your chat with @rednet-gov. Your report is " +
          "private - the person you reported and other members can't see it.",
        hasCloseButton: true,
      });
    } catch {
      setBusy(false);
      setError(
        "Couldn't send the report. Open your chat with @rednet-gov and send it there, or try again.",
      );
    }
  };

  return (
    <BaseDialog
      title="Report to organizers"
      onFinished={() => onFinished(false)}
    >
      <p>
        This privately alerts your organizers about a message from{" "}
        <strong>{sender}</strong>. They&apos;ll follow up in your chat with
        @rednet-gov. The person you report is not notified.
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
        element="textarea"
        label="What's wrong with this message?"
        value={reason}
        onChange={(e: React.ChangeEvent<HTMLTextAreaElement>) =>
          setReason(e.target.value)
        }
      />
      <DialogButtons
        primaryButton={busy ? "Sending…" : "Send report"}
        primaryButtonClass="danger"
        primaryDisabled={busy}
        onPrimaryButtonClick={submit}
        onCancel={() => onFinished(false)}
      />
    </BaseDialog>
  );
}
