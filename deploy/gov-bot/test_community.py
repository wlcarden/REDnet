"""Tests for community management commands (community.py).

Same boundaries as test_bot.py: mock the HTTP side-effects (reply, room
creation, state PUTs) and the audit log, exercise the real parsing, tier
mapping, request queue, and authorization logic.
"""

import os
import sys
from unittest.mock import patch

import pytest

os.environ.setdefault("REDNET_DOMAIN", "test.example")
os.environ.setdefault("GOV_BOT_TOKEN", "fake-bot-token")
os.environ.setdefault("SYS_TOKEN", "fake-sys-token")
os.environ.setdefault("REDNET_ACCESS_URL", "http://synapse:8008")

sys.path.insert(0, os.path.dirname(__file__))
import bot
import community

GOV = "!govroom:test"


# ── pure helpers ─────────────────────────────────────────────────────────────


class TestHelpers:
    def test_slug_basic(self):
        assert community._slug("Kitchen Crew") == "kitchen-crew"

    def test_slug_strips_special(self):
        assert community._slug("Ops / Intel #2!") == "ops--intel-2"

    def test_slug_empty_for_symbols(self):
        assert community._slug("!!!") == ""

    def test_join_rules_open_scoped_to_parent(self):
        jr = community.join_rules_for("open", "!space:test")
        assert jr["join_rule"] == "restricted"
        assert jr["allow"] == [{"type": "m.room_membership", "room_id": "!space:test"}]

    def test_join_rules_knock(self):
        assert community.join_rules_for("knock", "!s:test") == {"join_rule": "knock"}

    def test_join_rules_private(self):
        assert community.join_rules_for("private", "!s:test") == {"join_rule": "invite"}

    def test_default_visibility_is_knock(self):
        # Fails closed: a forgotten flag must not produce an open room.
        assert community.DEFAULT_VISIBILITY == "knock"

    def test_new_request_id_avoids_collisions(self):
        existing = [{"type": "room-request", "id": "REQ-aaaaaa"}]
        rid = community.new_request_id(existing)
        assert rid.startswith("REQ-")
        assert rid != "REQ-aaaaaa"

    def test_pending_requests_excludes_decided(self):
        records = [
            {"type": "room-request", "id": "REQ-1"},
            {"type": "room-request", "id": "REQ-2"},
            {"type": "room-request-decision", "id": "REQ-1", "decision": "approved"},
        ]
        pending = community.pending_requests(records)
        assert [r["id"] for r in pending] == ["REQ-2"]


# ── cmd_room ─────────────────────────────────────────────────────────────────


class TestCmdRoom:
    def setup_method(self):
        bot.ROOM_IDS["community"] = "!community:test"

    @patch.object(bot, "reply")
    def test_usage_without_name(self, mock_reply):
        community.cmd_room(GOV, "@org:test", [])
        assert "Usage" in mock_reply.call_args[0][1]

    @patch.object(bot, "reply")
    def test_rejects_bad_visibility(self, mock_reply):
        community.cmd_room(GOV, "@org:test", ["Name", "--visibility", "public"])
        assert "Unknown visibility" in mock_reply.call_args[0][1]

    @patch.object(bot, "reply")
    def test_unlisted_requires_private(self, mock_reply):
        community.cmd_room(
            GOV, "@org:test", ["Name", "--unlisted", "--visibility", "open"]
        )
        assert "--unlisted" in mock_reply.call_args[0][1]

    @patch.object(bot, "reply")
    @patch.object(bot, "resolve_alias", return_value="!exists:test")
    def test_rejects_existing_alias(self, mock_resolve, mock_reply):
        community.cmd_room(GOV, "@org:test", ["General"])
        assert "already exists" in mock_reply.call_args[0][1]

    @patch.object(bot, "append_vouch_jsonl")
    @patch.object(bot, "reply")
    @patch.object(bot, "resolve_alias", return_value="")
    @patch.object(community, "link_child", return_value=True)
    @patch.object(community, "create_managed_room", return_value=("!new:test", ""))
    def test_creates_knock_room_by_default(
        self, mock_create, mock_link, mock_resolve, mock_reply, mock_append
    ):
        community.cmd_room(GOV, "@org:test", ["Kitchen Crew"])
        name, visibility, parent, topic, alias = mock_create.call_args[0]
        assert name == "Kitchen Crew"
        assert visibility == "knock"
        assert parent == "!community:test"
        assert alias == "kitchen-crew"
        record = mock_append.call_args[0][0]
        assert record["type"] == "room"
        assert record["visibility"] == "knock"
        assert record["created_by"] == "@org:test"
        assert "knock" in mock_reply.call_args[0][1]

    @patch.object(bot, "append_vouch_jsonl")
    @patch.object(bot, "reply")
    @patch.object(bot, "resolve_alias", return_value="")
    @patch.object(community, "link_child", return_value=True)
    @patch.object(community, "create_managed_room", return_value=("!new:test", ""))
    @patch.object(bot, "set_power_level")
    @patch.object(bot, "invite_user")
    def test_requested_by_gets_moderator(
        self,
        mock_invite,
        mock_pl,
        mock_create,
        mock_link,
        mock_resolve,
        mock_reply,
        mock_append,
    ):
        community.cmd_room(
            GOV,
            "@org:test",
            ["Kitchen"],
            requested_by="@member:test",
            request_id="REQ-1",
        )
        mock_invite.assert_called_once_with("!new:test", "@member:test")
        mock_pl.assert_called_once_with("!new:test", "@member:test", 50)
        record = mock_append.call_args[0][0]
        assert record["requested_by"] == "@member:test"

    @patch.object(bot, "append_vouch_jsonl")
    @patch.object(bot, "reply")
    @patch.object(bot, "resolve_alias", return_value="")
    @patch.object(community, "link_child", return_value=True)
    @patch.object(community, "create_managed_room", return_value=("", "server said no"))
    def test_creation_failure_reported(
        self, mock_create, mock_link, mock_resolve, mock_reply, mock_append
    ):
        result = community.cmd_room(GOV, "@org:test", ["Kitchen"])
        assert result is None
        assert "failed" in mock_reply.call_args[0][1]
        mock_append.assert_not_called()

    @patch.object(bot, "append_vouch_jsonl")
    @patch.object(bot, "reply")
    @patch.object(bot, "resolve_alias", return_value="")
    @patch.object(community, "link_child")
    @patch.object(community, "create_managed_room", return_value=("!new:test", ""))
    def test_unlisted_private_never_linked(
        self, mock_create, mock_link, mock_resolve, mock_reply, mock_append
    ):
        community.cmd_room(
            GOV, "@org:test", ["Intel", "--visibility", "private", "--unlisted"]
        )
        mock_link.assert_not_called()
        record = mock_append.call_args[0][0]
        assert record["unlisted"] is True
        assert "unlisted" in mock_reply.call_args[0][1]


# ── request flow ─────────────────────────────────────────────────────────────


class TestRequestFlow:
    def setup_method(self):
        bot.GOV_BOT_ROOM_ID = GOV

    @patch.object(bot, "reply")
    def test_request_requires_kind(self, mock_reply):
        community.cmd_request("!dm:test", "@member:test", ["Kitchen"])
        assert "Usage" in mock_reply.call_args[0][1]

    @patch.object(bot, "reply")
    def test_request_requires_why(self, mock_reply):
        community.cmd_request("!dm:test", "@member:test", ["room", "Kitchen"])
        assert "--why" in mock_reply.call_args[0][1]

    @patch.object(bot, "send_notice")
    @patch.object(bot, "append_vouch_jsonl")
    @patch.object(bot, "read_vouch_jsonl", return_value=[])
    @patch.object(bot, "reply")
    def test_request_recorded_and_forwarded(
        self, mock_reply, mock_read, mock_append, mock_notice
    ):
        community.cmd_request(
            "!dm:test", "@member:test", ["room", "Kitchen", "--why", "food runs"]
        )
        record = mock_append.call_args[0][0]
        assert record["type"] == "room-request"
        assert record["requester"] == "@member:test"
        assert record["why"] == "food runs"
        # forwarded to #gov-bot, confirmed in the DM
        assert mock_notice.call_args[0][0] == GOV
        assert record["id"] in mock_notice.call_args[0][1]
        assert record["id"] in mock_reply.call_args[0][1]

    @patch.object(bot, "reply")
    @patch.object(bot, "read_vouch_jsonl", return_value=[])
    def test_requests_empty(self, mock_read, mock_reply):
        community.cmd_requests(GOV, "@org:test", [])
        assert "No pending" in mock_reply.call_args[0][1]

    @patch.object(bot, "reply")
    def test_approve_unknown_id(self, mock_reply):
        with patch.object(bot, "read_vouch_jsonl", return_value=[]):
            community.cmd_approve(GOV, "@org:test", ["REQ-nope"])
        assert "No pending request" in mock_reply.call_args[0][1]

    @patch.object(community, "dm_user")
    @patch.object(bot, "append_vouch_jsonl")
    @patch.object(community, "cmd_room", return_value="!new:test")
    def test_approve_creates_and_notifies(self, mock_room, mock_append, mock_dm):
        req = {
            "type": "room-request",
            "id": "REQ-1",
            "requester": "@member:test",
            "kind": "room",
            "name": "Kitchen",
            "why": "food",
        }
        with patch.object(bot, "read_vouch_jsonl", return_value=[req]):
            community.cmd_approve(GOV, "@org:test", ["REQ-1"])
        # request's requester threaded into creation
        assert mock_room.call_args.kwargs["requested_by"] == "@member:test"
        decision = mock_append.call_args[0][0]
        assert decision["type"] == "room-request-decision"
        assert decision["decision"] == "approved"
        assert mock_dm.call_args[0][0] == "@member:test"
        assert "approved" in mock_dm.call_args[0][1]

    @patch.object(community, "dm_user")
    @patch.object(bot, "append_vouch_jsonl")
    @patch.object(community, "cmd_room", return_value=None)
    def test_approve_failure_keeps_request_pending(
        self, mock_room, mock_append, mock_dm
    ):
        req = {
            "type": "room-request",
            "id": "REQ-1",
            "requester": "@member:test",
            "kind": "room",
            "name": "Kitchen",
        }
        with patch.object(bot, "read_vouch_jsonl", return_value=[req]):
            community.cmd_approve(GOV, "@org:test", ["REQ-1"])
        mock_append.assert_not_called()
        mock_dm.assert_not_called()

    @patch.object(community, "dm_user")
    @patch.object(bot, "append_vouch_jsonl")
    @patch.object(bot, "reply")
    def test_deny_records_and_notifies(self, mock_reply, mock_append, mock_dm):
        req = {
            "type": "room-request",
            "id": "REQ-1",
            "requester": "@member:test",
            "kind": "room",
            "name": "Kitchen",
        }
        with patch.object(bot, "read_vouch_jsonl", return_value=[req]):
            community.cmd_deny(GOV, "@org:test", ["REQ-1", "not", "right", "now"])
        decision = mock_append.call_args[0][0]
        assert decision["decision"] == "denied"
        assert decision["reason"] == "not right now"
        assert "declined" in mock_dm.call_args[0][1]


# ── archive / delete ─────────────────────────────────────────────────────────


class TestLifecycle:
    @patch.object(bot, "append_vouch_jsonl")
    @patch.object(bot, "reply")
    @patch.object(community, "get_state_parent", return_value="!parent:test")
    @patch.object(community, "unlink_child")
    @patch.object(community, "put_state", return_value=True)
    @patch.object(community, "get_state", return_value={"events_default": 0})
    @patch.object(community, "resolve_room_ref", return_value="!room:test")
    def test_archive_locks_and_unlinks(
        self,
        mock_ref,
        mock_get,
        mock_put,
        mock_unlink,
        mock_parent,
        mock_reply,
        mock_append,
    ):
        community.cmd_archive(GOV, "@org:test", ["kitchen"])
        pl_content = mock_put.call_args_list[0][0][3]
        assert pl_content["events_default"] == 100
        jr_content = mock_put.call_args_list[1][0][3]
        assert jr_content == {"join_rule": "invite"}
        mock_unlink.assert_called_once_with("!parent:test", "!room:test")
        assert mock_append.call_args[0][0]["type"] == "room-archived"

    @patch.object(bot, "reply")
    def test_delete_requires_confirm(self, mock_reply):
        community.cmd_delete(GOV, "@admin:test", ["kitchen"])
        assert "--confirm" in mock_reply.call_args[0][1]

    @patch.object(bot, "reply")
    @patch.object(community, "resolve_room_ref", return_value="!community:test")
    def test_delete_refuses_system_rooms(self, mock_ref, mock_reply):
        bot.ROOM_IDS["community"] = "!community:test"
        community.cmd_delete(GOV, "@admin:test", ["community", "--confirm"])
        assert "Refusing" in mock_reply.call_args[0][1]


# ── room sweep canaries ──────────────────────────────────────────────────────


def _sweep_response(rooms, total=None):
    class R:
        status_code = 200

        def json(self):
            return {"rooms": rooms, "total_rooms": total or len(rooms)}

    return R()


class TestRoomCanaries:
    def test_unencrypted_shared_room_flagged(self):
        rooms = [
            {
                "room_id": "!x:test",
                "canonical_alias": "#rogue:test",
                "joined_members": 5,
                "encryption": None,
                "creator": "@rednet-system:test",
            }
        ]
        with patch.object(community.http, "get", return_value=_sweep_response(rooms)):
            alerts = community.room_canaries()
        assert any("UNENCRYPTED" in a and "rogue" in a for a in alerts)

    def test_allowlisted_plaintext_rooms_pass(self):
        rooms = [
            {
                "room_id": "!g:test",
                "canonical_alias": "#gov-bot:test",
                "joined_members": 4,
                "encryption": None,
                "creator": "@rednet-gov:test",
            },
            {
                "room_id": "!w:test",
                "canonical_alias": "#welcome:test",
                "joined_members": 20,
                "encryption": None,
                "creator": "@rednet-system:test",
            },
        ]
        with patch.object(community.http, "get", return_value=_sweep_response(rooms)):
            assert community.room_canaries() == []

    def test_spaces_and_dms_pass_unencrypted(self):
        rooms = [
            {
                "room_id": "!s:test",
                "canonical_alias": "#community:test",
                "joined_members": 30,
                "encryption": None,
                "room_type": "m.space",
                "creator": "@rednet-system:test",
            },
            {
                "room_id": "!dm:test",
                "canonical_alias": None,
                "joined_members": 2,
                "encryption": None,
                "creator": "@member:test",
            },
        ]
        with patch.object(community.http, "get", return_value=_sweep_response(rooms)):
            assert community.room_canaries() == []

    def test_grown_dm_flagged_as_unmanaged(self):
        # The module's accepted residual risk: a spoofed "DM" that grew.
        rooms = [
            {
                "room_id": "!sneaky:test",
                "canonical_alias": None,
                "joined_members": 6,
                "encryption": {"algorithm": "m.megolm.v1.aes-sha2"},
                "creator": "@member:test",
            }
        ]
        with patch.object(community.http, "get", return_value=_sweep_response(rooms)):
            alerts = community.room_canaries()
        assert any("UNMANAGED" in a and "@member:test" in a for a in alerts)

    def test_encrypted_managed_room_passes(self):
        rooms = [
            {
                "room_id": "!k:test",
                "canonical_alias": "#kitchen:test",
                "joined_members": 8,
                "encryption": {"algorithm": "m.megolm.v1.aes-sha2"},
                "creator": "@rednet-system:test",
            }
        ]
        with patch.object(community.http, "get", return_value=_sweep_response(rooms)):
            assert community.room_canaries() == []

    def test_admin_api_denied_reports_skip(self):
        class R:
            status_code = 403

            def json(self):
                return {}

        with patch.object(community.http, "get", return_value=R()):
            alerts = community.room_canaries()
        assert any("SWEEP SKIPPED" in a for a in alerts)

    def test_sweep_unreachable_reports_skip(self):
        with patch.object(community.http, "get", side_effect=OSError("boom")):
            alerts = community.room_canaries()
        assert any("SWEEP SKIPPED" in a for a in alerts)


# ── dispatch integration (PL gates through bot.handle_command) ──────────────


class TestDispatch:
    @patch.object(bot, "get_power_level", return_value=0)
    @patch.object(bot, "reply")
    def test_member_cannot_create_room(self, mock_reply, mock_pl):
        bot.handle_command(GOV, "@member:test", '!gov room "Sneaky"')
        assert "Insufficient" in mock_reply.call_args[0][1]

    @patch.object(bot, "get_power_level", return_value=75)
    @patch.object(bot, "reply")
    def test_organizer_cannot_delete(self, mock_reply, mock_pl):
        bot.handle_command(GOV, "@org:test", "!gov delete kitchen --confirm")
        assert "Insufficient" in mock_reply.call_args[0][1]

    @patch.object(bot, "get_power_level", return_value=0)
    @patch.object(bot, "reply")
    def test_help_lists_community_commands(self, mock_reply, mock_pl):
        bot.handle_command(GOV, "@member:test", "!gov help")
        body = mock_reply.call_args[0][1]
        assert "room" in body
        assert "approve" in body
        assert "archive" in body

    @patch.object(community, "cmd_request")
    def test_dm_routes_request(self, mock_request):
        community.handle_dm_gov(
            "!dm:test", "@member:test", '!gov request room "X" --why "y"'
        )
        assert mock_request.called

    @patch.object(bot, "reply")
    def test_dm_other_commands_get_hint(self, mock_reply):
        community.handle_dm_gov("!dm:test", "@member:test", "!gov rooms")
        assert "request" in mock_reply.call_args[0][1]


# ── script-execution regression ──────────────────────────────────────────────


def test_bot_runs_as_script():
    """python3 bot.py names the module __main__, not `bot` — the import cycle
    with community.py must survive that (it crashed the container once)."""
    import subprocess

    result = subprocess.run(
        [sys.executable, "bot.py", "--check-imports"],
        capture_output=True,
        text=True,
        timeout=30,
        cwd=os.path.dirname(os.path.abspath(__file__)),
        env={**os.environ},
    )
    assert result.returncode == 0, result.stderr
    assert "imports ok" in result.stdout
