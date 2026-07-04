/*
 * REDnet "Panic — wipe this device" dialog (soft-fork UI).
 *
 * The coercion control (THREAT-MODEL / COMMUNITY-MANAGEMENT "Duress / panic control"):
 * a member whose device is seized, force-unlocked, or who is pressured to hand over
 * their account, hits ONE confirm-gated control that both (a) SIGNALS the community and
 * (b) WIPES this device.
 *
 * On confirm we send the plaintext governance signal `!duress` to the member's DM with
 * @rednet-gov — the gov bot's handle_duress SELF-LOCKS the sender's account (a reversible
 * MAS lock that kills every session server-side) and alerts organizers — and THEN we fully
 * sign out and clear the local store (crypto keys + session + IndexedDB) via Element's
 * logout action.
 *
 * CRITICAL ordering + failure policy: the local wipe MUST happen even if the signal can't
 * be sent — under duress the network may be cut. So the send is best-effort and
 * time-bounded; the wipe always runs. We also dispatch `logout` directly to BYPASS
 * Element's "back up your keys first" logout warning on purpose — a panic wipe wants the
 * data GONE, not preserved.
 *
 * Self-contained so the UserMenu patch is a one-line menu item. Copied into
 * src/components/views/dialogs/ by the Dockerfile. Hardcoded English (the fork ships en
 * only), which also sidesteps Element's compile-time _t() key gating.
 */
import React, { useState } from "react";

import BaseDialog from "./BaseDialog";
import DialogButtons from "../elements/DialogButtons";
import { MatrixClientPeg } from "../../../MatrixClientPeg";
import { ensureDMExists } from "../../../createRoom";
import defaultDispatcher from "../../../dispatcher/dispatcher";

interface IProps {
  onFinished: (wiped?: boolean) => void;
}

// A best-effort signal must never strand the user with an un-wiped device: if the
// network is cut, bound the wait to a few seconds, then wipe regardless.
const SIGNAL_TIMEOUT_MS = 4000;

export default function RednetPanicDialog({ onFinished }: IProps): JSX.Element {
  const [busy, setBusy] = useState(false);

  const panic = async (): Promise<void> => {
    setBusy(true);

    // (a) Best-effort, time-bounded signal to the gov bot. Swallow every error —
    // the wipe in (b) is the priority and must run whether or not this succeeds.
    try {
      const cli = MatrixClientPeg.safeGet();
      const domain = cli.getDomain();
      if (domain) {
        const govMxid = `@rednet-gov:${domain}`;
        const send = (async (): Promise<void> => {
          const roomId = await ensureDMExists(cli, govMxid);
          if (roomId) await cli.sendTextMessage(roomId, "!duress");
        })().catch(() => {
          /* offline / cut network — fall through to the wipe */
        });
        const timeout = new Promise<void>((r) =>
          setTimeout(r, SIGNAL_TIMEOUT_MS),
        );
        await Promise.race([send, timeout]);
      }
    } catch {
      /* never block the wipe on the signal */
    }

    // (b) Full sign-out + local wipe. Element's logout action runs onLoggedOut() ->
    // clearStorage({ deleteEverything: true }), which drops the crypto store
    // (clearStores), localStorage, sessionStorage and the session token. Dispatched
    // directly so we skip Element's "back up your keys" warning — a panic wipe wants
    // the data gone now. This tears down the client and returns to a blank login.
    onFinished(true);
    defaultDispatcher.dispatch({ action: "logout" });
  };

  return (
    <BaseDialog
      title="Panic — wipe this device"
      onFinished={() => onFinished(false)}
    >
      <p>
        This signs you out here and <strong>erases this device</strong>:
        messages, encryption keys and your session are removed, and it returns
        to a blank login screen.
      </p>
      <p>
        It also alerts your organizers and <strong>locks your account</strong>{" "}
        so it can&apos;t be used from any device. This is reversible — when
        you&apos;re safe, an organizer restores your access and your rooms and
        history come back.
      </p>
      <DialogButtons
        primaryButton={busy ? "Wiping…" : "Sign out & wipe this device"}
        primaryButtonClass="danger"
        primaryDisabled={busy}
        onPrimaryButtonClick={panic}
        onCancel={() => onFinished(false)}
      />
    </BaseDialog>
  );
}
