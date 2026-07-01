"""REDnet room creation policy — Synapse third-party-rules module.

Locks room/space creation to the system accounts so every shared room is born
through the gov bot (E2EE, in-hierarchy, audit-logged — COMMUNITY-MANAGEMENT.md).
Members' clients keep working for DMs: a creation request shaped like a DM
(is_direct, no alias, at most one invite, private preset) is allowed for anyone.

Wired by setup.sh:
    modules:
      - module: rednet_room_policy.RednetRoomPolicy
        config:
          allowed_creators: ["@rednet-system:DOMAIN", "@rednet-gov:DOMAIN", "@rednet-mod:DOMAIN"]

on_create_room(requester, request_content, is_requester_admin) receives the
full createRoom body and denies by raising SynapseError — the message is shown
verbatim in the client's error dialog, so it doubles as member-facing UX.
(Documented at modules/third_party_rules_callbacks.html; our pin is 1.155.0.)
"""

import logging

from synapse.module_api import ModuleApi
from synapse.module_api.errors import Codes, SynapseError

logger = logging.getLogger(__name__)

DENY_MESSAGE = (
    "Room creation goes through your organizers. "
    'Open your Gov Bot DM and type: !gov request room "Name" --why "purpose"'
)

# DM shape: what Element sends for a direct chat. Anything outside this shape
# from a non-system account is denied.
DM_PRESETS = {"trusted_private_chat", "private_chat", None}


def is_dm_shaped(request_content):
    """True when a createRoom body looks like a 1:1 direct chat.

    Policy, not cryptography: a custom client can spoof this shape to get a
    1:1 room. It cannot attach an alias (alias_creation_rules) or grow the
    room unnoticed (the audit sweep flags is_direct rooms with >2 members).
    """
    if not request_content.get("is_direct"):
        return False
    if request_content.get("room_alias_name"):
        return False
    if len(request_content.get("invite", [])) > 1:
        return False
    if request_content.get("preset") not in DM_PRESETS:
        return False
    # A "DM" that is secretly a space is not a DM.
    if (request_content.get("creation_content") or {}).get("type"):
        return False
    return True


def may_create(user_id, request_content, is_admin, allowed):
    """Pure decision function — unit-tested without Synapse installed."""
    if is_admin or user_id in allowed:
        return True
    return is_dm_shaped(request_content)


class RednetRoomPolicy:
    def __init__(self, config, api: ModuleApi):
        self._allowed = set(config.get("allowed_creators", []))
        if not self._allowed:
            # An empty allowlist would brick bootstrap (the system account
            # couldn't create rooms). Fail loudly at startup, not at runtime.
            raise ValueError(
                "rednet_room_policy: allowed_creators must list the system accounts"
            )
        api.register_third_party_rules_callbacks(
            on_create_room=self.on_create_room,
        )
        logger.info("rednet_room_policy active — creators: %s", sorted(self._allowed))

    async def on_create_room(self, requester, request_content, is_requester_admin):
        user_id = requester.user.to_string()
        if may_create(user_id, request_content, is_requester_admin, self._allowed):
            return
        logger.info(
            "rednet_room_policy: denied room creation by %s (is_direct=%s alias=%s invites=%d)",
            user_id,
            request_content.get("is_direct"),
            request_content.get("room_alias_name"),
            len(request_content.get("invite", [])),
        )
        raise SynapseError(403, DENY_MESSAGE, Codes.FORBIDDEN)
