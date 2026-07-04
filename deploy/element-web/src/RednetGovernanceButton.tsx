/*
 * REDnet governance dashboard nav button (soft-fork UI).
 *
 * The governance dashboard (mint / vouch-graph / audit) is served at /governance/ and lives
 * today only as a widget inside #governance. This promotes it to a persistent button in the
 * space-panel footer so organizers reach it without hunting.
 *
 * Organizer-gated: members are not in #governance (it lives in the Organizing sub-space), so
 * the button renders ONLY for a user who is a PL>=75 member of #governance. A non-organizer
 * never sees a dashboard they can't use. The dashboard itself also auth-gates server-side
 * (mint_endpoint verifies PL via the Matrix OpenID token), so this is UX, not the security
 * boundary.
 *
 * Self-contained so the SpacePanel patch is a one-line insert. Copied into
 * src/components/views/spaces/ by the Dockerfile. English-only (the fork ships en only).
 */
import React from "react";

import AccessibleButton from "../elements/AccessibleButton";
import { MatrixClientPeg } from "../../../MatrixClientPeg";

function isOrganizer(): boolean {
  const cli = MatrixClientPeg.get();
  const me = cli?.getUserId();
  if (!cli || !me) return false;
  return cli.getRooms().some((r) => {
    const alias = r.getCanonicalAlias();
    if (!alias || !alias.startsWith("#governance:")) return false;
    return (r.getMember(me)?.powerLevel ?? 0) >= 75;
  });
}

export default function RednetGovernanceButton(): JSX.Element | null {
  if (!isOrganizer()) return null;
  return (
    <AccessibleButton
      className="mx_RednetGovernanceButton"
      onClick={() =>
        window.open("/governance/", "_blank", "noopener,noreferrer")
      }
      title="Governance dashboard"
      aria-label="Governance dashboard"
    >
      <span className="mx_RednetGovernanceButton_icon" aria-hidden="true" />
    </AccessibleButton>
  );
}
