/*
 * REDnet governance menu button (soft-fork UI).
 *
 * A persistent organizer-only button in the space-panel footer that opens a small menu of the
 * governance surfaces that otherwise live only in chat commands or the standalone dashboard:
 *   - Governance dashboard -> opens /governance/ (mint / vouch-graph / audit)
 *   - Pending requests      -> RednetRequestsDialog (approve/deny member room requests)
 *
 * Organizer-gated: members aren't in #governance, so the button renders ONLY for a PL>=75
 * member of #governance. A non-organizer never sees governance they can't use; the underlying
 * surfaces also auth-gate server-side, so this is UX, not the security boundary.
 *
 * Self-contained so the SpacePanel patch is a one-line insert. Copied into
 * src/components/views/spaces/ by the Dockerfile. English-only (the fork ships en only).
 */
import React from "react";

import AccessibleButton from "../elements/AccessibleButton";
import {
  alwaysAboveRightOf,
  ChevronFace,
  useContextMenu,
} from "../../structures/ContextMenu";
import IconizedContextMenu, {
  IconizedContextMenuOption,
  IconizedContextMenuOptionList,
} from "../context_menus/IconizedContextMenu";
import Modal from "../../../Modal";
import { MatrixClientPeg } from "../../../MatrixClientPeg";
import RednetRequestsDialog from "../dialogs/RednetRequestsDialog";
import RednetInviteDialog from "../dialogs/RednetInviteDialog";
import RednetCreateRoomDialog from "../dialogs/RednetCreateRoomDialog";
import RednetInviteToRoomDialog from "../dialogs/RednetInviteToRoomDialog";

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
  const [menuDisplayed, handle, openMenu, closeMenu] =
    useContextMenu<HTMLDivElement>();
  if (!isOrganizer()) return null;

  let contextMenu: JSX.Element | undefined;
  if (menuDisplayed && handle.current) {
    contextMenu = (
      <IconizedContextMenu
        {...alwaysAboveRightOf(
          handle.current.getBoundingClientRect(),
          ChevronFace.None,
          16,
        )}
        onFinished={closeMenu}
        compact
      >
        <IconizedContextMenuOptionList first>
          <IconizedContextMenuOption
            label="Governance dashboard"
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              closeMenu();
              window.open("/governance/", "_blank", "noopener,noreferrer");
            }}
          />
          <IconizedContextMenuOption
            label="Pending requests"
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              closeMenu();
              Modal.createDialog(RednetRequestsDialog, {});
            }}
          />
          <IconizedContextMenuOption
            label="Invite someone"
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              closeMenu();
              Modal.createDialog(RednetInviteDialog, {});
            }}
          />
          <IconizedContextMenuOption
            label="Create room or space"
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              closeMenu();
              Modal.createDialog(RednetCreateRoomDialog, {});
            }}
          />
          <IconizedContextMenuOption
            label="Add a member to a room"
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              closeMenu();
              Modal.createDialog(RednetInviteToRoomDialog, {});
            }}
          />
        </IconizedContextMenuOptionList>
      </IconizedContextMenu>
    );
  }

  return (
    <>
      <AccessibleButton
        className="mx_RednetGovernanceButton"
        onClick={openMenu}
        ref={handle}
        title="Governance"
        aria-label="Governance"
      >
        <span className="mx_RednetGovernanceButton_icon" aria-hidden="true" />
      </AccessibleButton>
      {contextMenu}
    </>
  );
}
