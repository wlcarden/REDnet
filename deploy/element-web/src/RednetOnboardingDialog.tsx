/*
 * REDnet first-run onboarding checklist (soft-fork UI).
 *
 * The safety basics a new member needs (save your passphrase, kill lock-screen previews, keep
 * your identity out of chat, know the retention window) delivered as a one-time in-app modal
 * instead of only a gov-bot chat message that scrolls away. Shown once per device (a
 * localStorage flag set by the MatrixChat patch before this opens).
 *
 * Self-contained so the MatrixChat patch is a one-line trigger — and deliberately SEPARATE
 * from integration.patch (the recovery-critical silent-onboarding hook), so a re-anchor here
 * can never affect crypto bootstrap. Copied into src/components/views/dialogs/ by the
 * Dockerfile. Hardcoded English (the fork ships en only).
 */
import React, { useState } from "react";

import BaseDialog from "./BaseDialog";
import DialogButtons from "../elements/DialogButtons";

interface IProps {
  onFinished: () => void;
}

const ITEMS: { t: string; d: string }[] = [
  {
    t: "Save your recovery passphrase",
    d: "You saw it once when you joined. Store it somewhere safe and offline — it's the only way back into your account on a new device.",
  },
  {
    t: "Turn off lock-screen message previews",
    d: "Previews show message content on your locked screen, bypassing encryption. Disable them in your phone's notification settings.",
  },
  {
    t: "Keep your identity out of chat",
    d: "Your username and display name are visible to anyone with server access. Don't use your real name, and keep real names, locations and faces out of messages.",
  },
  {
    t: "Know the retention window",
    d: "Chat auto-deletes after a few days, by design. Public-safe references like crisis lines and legal aid live on the permanent reference page; sensitive specifics like meeting points stay in chat, where they roll off.",
  },
];

export default function RednetOnboardingDialog({
  onFinished,
}: IProps): JSX.Element {
  const [checked, setChecked] = useState<boolean[]>(ITEMS.map(() => false));
  const toggle = (i: number): void =>
    setChecked((c) => c.map((v, j) => (j === i ? !v : v)));

  return (
    <BaseDialog title="Welcome — a few safety basics" onFinished={onFinished}>
      <p style={{ marginTop: 0 }}>
        A minute now keeps you safer here. Tick each as you go — you can revisit
        all of this in the member guide and the reference page.
      </p>
      <ul style={{ listStyle: "none", padding: 0, margin: "0 0 8px" }}>
        {ITEMS.map((item, i) => (
          <li
            key={i}
            style={{
              display: "flex",
              gap: "10px",
              padding: "10px 0",
              borderTop: "1px solid rgba(255,255,255,0.06)",
            }}
          >
            <input
              type="checkbox"
              checked={checked[i]}
              onChange={() => toggle(i)}
              aria-label={item.t}
              style={{
                marginTop: "3px",
                accentColor: "#E5484D",
                flex: "0 0 auto",
              }}
            />
            <span>
              <strong style={{ display: "block" }}>{item.t}</strong>
              <span
                style={{ color: "var(--cpd-color-text-secondary, #8B8D98)" }}
              >
                {item.d}
              </span>
            </span>
          </li>
        ))}
      </ul>
      <DialogButtons
        primaryButton="Got it"
        onPrimaryButtonClick={onFinished}
        hasCancel={false}
      />
    </BaseDialog>
  );
}
