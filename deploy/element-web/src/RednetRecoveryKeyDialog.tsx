/*
 * REDnet recovery-passphrase dialog (soft-fork UI). Two modes:
 *   "show"   — display the generated passphrase ONCE on a fresh account ("save this").
 *   "prompt" — ask for the passphrase on a fresh device, to recover identity + message history.
 * The crypto lives in the rednet-onboarding MODULE; this is only the UI, invoked from MatrixChat's
 * silent-onboarding hook (the :REDNET: patch) via Element's Modal. Copied into element-web/src by the Dockerfile.
 */
import React, { useState } from "react";

import BaseDialog from "./components/views/dialogs/BaseDialog";
import DialogButtons from "./components/views/elements/DialogButtons";
import Field from "./components/views/elements/Field";

interface IProps {
  mode: "show" | "prompt";
  value?: string;
  error?: string;
  onFinished: (result?: string) => void;
}

export default function RednetRecoveryKeyDialog({
  mode,
  value,
  error,
  onFinished,
}: IProps): JSX.Element {
  const [input, setInput] = useState("");

  if (mode === "show") {
    return (
      <BaseDialog
        title="Save your recovery passphrase"
        hasCancel={false}
        onFinished={() => onFinished()}
      >
        <p>
          This passphrase is the <b>only</b> way to recover your account and
          message history on a new device. Write it down somewhere safe and
          offline. No one, not even the server operators, can recover it for
          you.
        </p>
        <pre
          style={{
            userSelect: "all",
            padding: "12px",
            borderRadius: "8px",
            background: "rgba(0,0,0,0.2)",
            whiteSpace: "pre-wrap",
            wordBreak: "break-word",
          }}
        >
          {value}
        </pre>
        <DialogButtons
          primaryButton="I've saved it"
          onPrimaryButtonClick={() => onFinished()}
          hasCancel={false}
        />
      </BaseDialog>
    );
  }

  return (
    <BaseDialog
      title="Enter your recovery passphrase"
      onFinished={() => onFinished(undefined)}
    >
      <p>
        Enter the recovery passphrase you saved when you joined, to restore your
        messages on this device.
      </p>
      {error && (
        <p
          style={{
            color: "var(--cpd-color-text-critical-primary, #ff5b55)",
            margin: "0 0 12px",
          }}
        >
          {error}
        </p>
      )}
      <Field
        type="password"
        label="Recovery passphrase"
        value={input}
        autoComplete="off"
        onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
          setInput(e.target.value)
        }
      />
      <DialogButtons
        primaryButton="Recover"
        onPrimaryButtonClick={() => onFinished(input)}
        onCancel={() => onFinished(undefined)}
      />
    </BaseDialog>
  );
}
