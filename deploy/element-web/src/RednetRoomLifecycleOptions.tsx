/*
 * REDnet room-lifecycle context-menu options (soft-fork UI).
 *
 * Adds organizer/admin room-lifecycle actions to a room's right-click menu (RoomGeneralContext
 * Menu), each opening a typed-confirm dialog:
 *   - Archive room (organizer, PL>=75 in #governance)
 *   - Delete room  (admin, PL>=100 in #governance)
 * Gated on the viewer's power level in #governance (members aren't in it -> 0), so a
 * non-organizer sees neither. The gov-bot re-checks PL server-side.
 *
 * Self-contained so the RoomGeneralContextMenu patch is a one-line insert. Copied into
 * src/components/views/context_menus/ by the Dockerfile. Hardcoded English.
 */
import React from "react";
import { Room } from "matrix-js-sdk/src/matrix";

import {
  IconizedContextMenuOption,
  IconizedContextMenuOptionList,
} from "./IconizedContextMenu";
import Modal from "../../../Modal";
import { MatrixClientPeg } from "../../../MatrixClientPeg";
import RednetRoomLifecycleDialog from "../dialogs/RednetRoomLifecycleDialog";

// Highest PL the current user holds in #governance (members aren't joined there -> 0).
function govPowerLevel(): number {
  const cli = MatrixClientPeg.get();
  const me = cli?.getUserId();
  if (!cli || !me) return 0;
  let pl = 0;
  cli.getRooms().forEach((r) => {
    const alias = r.getCanonicalAlias();
    if (alias && alias.startsWith("#governance:")) {
      pl = Math.max(pl, r.getMember(me)?.powerLevel ?? 0);
    }
  });
  return pl;
}

interface IProps {
  room: Room;
  onFinished?: () => void;
}

export default function RednetRoomLifecycleOptions({
  room,
  onFinished,
}: IProps): JSX.Element | null {
  const pl = govPowerLevel();
  if (pl < 75) return null; // organizer minimum (archive); delete needs 100

  const open =
    (action: "archive" | "delete") =>
    (e?: React.SyntheticEvent): void => {
      e?.preventDefault?.();
      e?.stopPropagation?.();
      onFinished?.();
      Modal.createDialog(RednetRoomLifecycleDialog, { room, action });
    };

  return (
    <IconizedContextMenuOptionList red>
      <IconizedContextMenuOption
        label="Archive room"
        onClick={open("archive")}
      />
      {pl >= 100 && (
        <IconizedContextMenuOption
          label="Delete room"
          onClick={open("delete")}
        />
      )}
    </IconizedContextMenuOptionList>
  );
}
