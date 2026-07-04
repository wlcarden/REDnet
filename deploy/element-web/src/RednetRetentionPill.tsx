/*
 * REDnet retention indicator (soft-fork UI).
 *
 * REDnet auto-deletes messages after a retention window (Synapse `retention` config,
 * default 7 days; some rooms carry a per-room `m.room.retention` override). Stock Element
 * has NO retention UI — the disappearing-message window is invisible. This pill makes it
 * visible in the room header so members can see how long messages last here.
 *
 * Data source (in priority order):
 *   1. durable rooms (config `org.rednet.retention.exempt_localparts`, e.g. #reference,
 *      #vouch-log) render NOTHING — they don't auto-delete;
 *   2. a per-room `m.room.retention` state event's `max_lifetime` (ms), if present;
 *   3. otherwise the deploy default `org.rednet.retention.default_days` (threaded from
 *      REDNET_RETENTION_DAYS via build.sh into config.json — the server default the client
 *      can't read from homeserver.yaml).
 *
 * Self-contained so the RoomHeader patch is a one-line insert. Copied into
 * src/components/views/rooms/ by the Dockerfile. English-only (the fork ships en only).
 */
import React from "react";
import { Room } from "matrix-js-sdk/src/matrix";

import SdkConfig from "../../../SdkConfig";

interface IProps {
  room: Room;
}

const MS_PER_DAY = 24 * 60 * 60 * 1000;

export default function RednetRetentionPill({
  room,
}: IProps): JSX.Element | null {
  const cfg = ((SdkConfig.get() as any) || {})["org.rednet.retention"] || {};
  const exempt: string[] = cfg.exempt_localparts || [];

  // #reference / #vouch-log and the like are durable — never show a window for them.
  const alias = room.getCanonicalAlias();
  const localpart = alias ? alias.slice(1).split(":")[0] : "";
  if (localpart && exempt.includes(localpart)) return null;

  let days = 0;
  const content = room.currentState
    ?.getStateEvents("m.room.retention", "")
    ?.getContent?.();
  const maxLifetime = content?.max_lifetime;
  if (typeof maxLifetime === "number" && maxLifetime > 0) {
    days = Math.ceil(maxLifetime / MS_PER_DAY);
  } else {
    days = Number(cfg.default_days) || 0;
  }
  if (days <= 0) return null;

  const label =
    days === 1
      ? "Messages here disappear after 1 day"
      : `Messages here disappear after ${days} days`;

  return (
    <span
      className="mx_RoomHeader_rednetRetention"
      title={label}
      aria-label={label}
    >
      {days}d
    </span>
  );
}
