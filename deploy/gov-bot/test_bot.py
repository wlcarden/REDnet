"""Tests for REDnet governance bot.

Covers command parsing, HTML sanitization, vouch index parsing,
audit canary logic, and power level authorization.
"""

import json
import os
import sys
import tempfile
from unittest.mock import MagicMock, patch

import pytest

os.environ.setdefault("REDNET_DOMAIN", "test.example")
os.environ.setdefault("GOV_BOT_TOKEN", "fake-bot-token")
os.environ.setdefault("SYS_TOKEN", "fake-sys-token")
os.environ.setdefault("REDNET_ACCESS_URL", "http://synapse:8008")

sys.path.insert(0, os.path.dirname(__file__))
import bot
import community


# ── parse_args / parse_flags ─────────────────────────────────────────────────


class TestParsing:
    def test_simple_args(self):
        assert bot.parse_args("!gov status") == ["!gov", "status"]

    def test_quoted_args(self):
        result = bot.parse_args('!gov report @alice --detail "suspicious login"')
        assert result == ["!gov", "report", "@alice", "--detail", "suspicious login"]

    def test_malformed_quotes_fallback(self):
        result = bot.parse_args('!gov report @alice --detail "unclosed')
        assert "@alice" in result

    def test_parse_flags_extracts_named(self):
        args = ["@alice", "--detail", "compromised device", "--severity", "confirmed"]
        pos, flags = bot.parse_flags(args, "detail", "severity")
        assert pos == ["@alice"]
        assert flags["detail"] == "compromised device"
        assert flags["severity"] == "confirmed"

    def test_parse_flags_missing_value(self):
        args = ["@alice", "--detail"]
        pos, flags = bot.parse_flags(args, "detail")
        assert pos == ["@alice"]
        assert "detail" not in flags

    def test_parse_flags_no_flags(self):
        args = ["@alice", "some", "freeform", "text"]
        pos, flags = bot.parse_flags(args, "detail")
        assert pos == ["@alice", "some", "freeform", "text"]
        assert flags == {}

    def test_parse_flags_unknown_dashes_kept_as_positional(self):
        args = ["@alice", "--unknown", "value"]
        pos, flags = bot.parse_flags(args, "detail")
        assert "--unknown" in pos
        assert "value" in pos


# ── _md_to_html (XSS prevention) ────────────────────────────────────────────


class TestHtmlSanitization:
    def test_escapes_angle_brackets(self):
        result = bot._md_to_html("<script>alert('xss')</script>")
        assert "<script>" not in result
        assert "&lt;script&gt;" in result

    def test_escapes_ampersands(self):
        result = bot._md_to_html("a & b")
        assert "&amp;" in result

    def test_bold_conversion(self):
        result = bot._md_to_html("**bold text**")
        assert "<strong>bold text</strong>" in result

    def test_code_conversion(self):
        result = bot._md_to_html("`code`")
        assert "<code>code</code>" in result

    def test_newlines_to_br(self):
        result = bot._md_to_html("line1\nline2")
        assert "<br>" in result

    def test_xss_in_bold(self):
        result = bot._md_to_html("**<img src=x onerror=alert(1)>**")
        assert "onerror" not in result or "&lt;" in result

    def test_nested_html_in_code(self):
        result = bot._md_to_html("`<div onclick=alert(1)>`")
        assert "onclick" not in result or "&lt;" in result


# ── read_vouch_jsonl ─────────────────────────────────────────────────────────


class TestVouchIndex:
    def test_reads_valid_jsonl(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as f:
            f.write('{"type":"vouch","voucher":"@alice","label":"test"}\n')
            f.write('{"type":"claimed","account":"@bob","voucher":"@alice"}\n')
            path = f.name
        try:
            with patch.object(bot, "VOUCH_PATH", path):
                records = bot.read_vouch_jsonl()
            assert len(records) == 2
            assert records[0]["type"] == "vouch"
            assert records[1]["account"] == "@bob"
        finally:
            os.unlink(path)

    def test_skips_blank_lines(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as f:
            f.write('{"type":"vouch"}\n\n\n{"type":"claimed"}\n')
            path = f.name
        try:
            with patch.object(bot, "VOUCH_PATH", path):
                records = bot.read_vouch_jsonl()
            assert len(records) == 2
        finally:
            os.unlink(path)

    def test_skips_malformed_json(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as f:
            f.write('{"type":"vouch"}\n')
            f.write("not json\n")
            f.write('{"type":"claimed"}\n')
            path = f.name
        try:
            with patch.object(bot, "VOUCH_PATH", path):
                records = bot.read_vouch_jsonl()
            assert len(records) == 2
        finally:
            os.unlink(path)

    def test_missing_file(self):
        with patch.object(bot, "VOUCH_PATH", "/nonexistent/vouch.jsonl"):
            records = bot.read_vouch_jsonl()
        assert records == []

    def test_append_vouch_jsonl(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as f:
            path = f.name
        try:
            with patch.object(bot, "VOUCH_PATH", path):
                bot.append_vouch_jsonl({"type": "test", "data": "value"})
            with open(path) as f:
                line = f.read().strip()
            record = json.loads(line)
            assert record["type"] == "test"
        finally:
            os.unlink(path)


# ── Audit canary logic ───────────────────────────────────────────────────────


class TestAuditLogic:
    @pytest.fixture(autouse=True)
    def _no_room_sweep(self):
        with patch.object(community, "room_canaries", return_value=[]):
            yield

    def _make_vouch(self, voucher, ts, token_hash="h"):
        return {
            "type": "vouch",
            "voucher": voucher,
            "token_hash": token_hash,
            "timestamp": ts,
        }

    def _make_claim(self, token_hash="h"):
        return {"type": "claimed", "token_hash": token_hash}

    @patch.object(bot, "read_vouch_jsonl")
    @patch.object(bot, "reply")
    def test_clean_audit(self, mock_reply, mock_read):
        mock_read.return_value = [
            self._make_vouch("@alice", "2020-01-01T00:00:00Z", "h1"),
            self._make_claim("h1"),
        ]
        bot.cmd_audit("!room:test", "@admin:test", [])
        mock_reply.assert_called_once()
        assert "clean" in mock_reply.call_args[0][1].lower()

    @patch.object(bot, "read_vouch_jsonl")
    @patch.object(bot, "reply")
    def test_burst_detection(self, mock_reply, mock_read):
        now = bot.now_iso()
        records = [self._make_vouch("@suspect", now, f"h{i}") for i in range(10)]
        mock_read.return_value = records
        bot.cmd_audit("!room:test", "@admin:test", [])
        mock_reply.assert_called_once()
        body = mock_reply.call_args[0][1]
        assert "BURST" in body
        assert "@suspect" in body

    @patch.object(bot, "read_vouch_jsonl")
    @patch.object(bot, "reply")
    def test_unclaimed_alert(self, mock_reply, mock_read):
        records = [
            self._make_vouch("@alice", "2020-01-01T00:00:00Z", f"h{i}")
            for i in range(10)
        ]
        mock_read.return_value = records
        bot.cmd_audit("!room:test", "@admin:test", [])
        mock_reply.assert_called_once()
        body = mock_reply.call_args[0][1]
        assert "UNCLAIMED" in body

    @patch.object(bot, "read_vouch_jsonl")
    @patch.object(bot, "reply")
    def test_stale_invite_alert(self, mock_reply, mock_read):
        records = [
            self._make_vouch("@alice", "2020-01-01T00:00:00Z", f"h{i}")
            for i in range(5)
        ]
        mock_read.return_value = records
        bot.cmd_audit("!room:test", "@admin:test", [])
        mock_reply.assert_called_once()
        body = mock_reply.call_args[0][1]
        assert "STALE" in body


# ── Command authorization ────────────────────────────────────────────────────


class TestAuthorization:
    @patch.object(bot, "get_power_level", return_value=0)
    @patch.object(bot, "reply")
    def test_member_cannot_audit(self, mock_reply, mock_pl):
        bot.handle_command("!room:test", "@member:test", "!gov audit")
        mock_reply.assert_called_once()
        assert "Insufficient" in mock_reply.call_args[0][1]

    @patch.object(bot, "get_power_level", return_value=0)
    @patch.object(bot, "reply")
    def test_member_cannot_revoke(self, mock_reply, mock_pl):
        bot.handle_command(
            "!room:test", "@member:test", '!gov revoke @user --reason "test"'
        )
        mock_reply.assert_called_once()
        assert "Insufficient" in mock_reply.call_args[0][1]

    @patch.object(bot, "get_power_level", return_value=50)
    @patch.object(bot, "reply")
    def test_moderator_cannot_revoke(self, mock_reply, mock_pl):
        bot.handle_command(
            "!room:test", "@mod:test", '!gov revoke @user --reason "test"'
        )
        mock_reply.assert_called_once()
        assert "Insufficient" in mock_reply.call_args[0][1]

    @patch.object(bot, "get_power_level", return_value=0)
    @patch.object(bot, "reply")
    def test_member_can_request_status(self, mock_reply, mock_pl):
        with patch.object(bot, "read_vouch_jsonl", return_value=[]):
            with patch.object(
                bot, "_server_health", return_value={"synapse": "up", "version": "v1.1"}
            ):
                bot.handle_command("!room:test", "@member:test", "!gov status")
        mock_reply.assert_called_once()
        assert "Gov Bot Status" in mock_reply.call_args[0][1]

    def test_bot_ignores_own_messages(self):
        with patch.object(bot, "reply") as mock_reply:
            bot.handle_command("!room:test", bot.BOT_USER, "!gov status")
        mock_reply.assert_not_called()

    @patch.object(bot, "get_power_level", return_value=0)
    @patch.object(bot, "reply")
    def test_unknown_command(self, mock_reply, mock_pl):
        bot.handle_command("!room:test", "@user:test", "!gov nonexistent")
        mock_reply.assert_called_once()
        assert "Unknown" in mock_reply.call_args[0][1]

    @patch.object(bot, "get_power_level", return_value=0)
    @patch.object(bot, "reply")
    def test_help_lists_commands(self, mock_reply, mock_pl):
        bot.handle_command("!room:test", "@user:test", "!gov help")
        mock_reply.assert_called_once()
        body = mock_reply.call_args[0][1]
        assert "status" in body
        assert "revoke" in body


# ── Command input validation ─────────────────────────────────────────────────


class TestInputValidation:
    @patch.object(bot, "get_power_level", return_value=100)
    @patch.object(bot, "reply")
    def test_revoke_requires_reason(self, mock_reply, mock_pl):
        bot.handle_command("!room:test", "@admin:test", "!gov revoke @target")
        mock_reply.assert_called_once()
        assert "reason" in mock_reply.call_args[0][1].lower()

    @patch.object(bot, "get_power_level", return_value=100)
    @patch.object(bot, "reply")
    def test_revoke_requires_target(self, mock_reply, mock_pl):
        bot.handle_command("!room:test", "@admin:test", '!gov revoke --reason "test"')
        mock_reply.assert_called_once()
        assert "Usage" in mock_reply.call_args[0][1]

    @patch.object(bot, "get_power_level", return_value=75)
    @patch.object(bot, "reply")
    def test_confirm_requires_target(self, mock_reply, mock_pl):
        bot.handle_command("!room:test", "@org:test", "!gov confirm")
        mock_reply.assert_called_once()
        assert "Usage" in mock_reply.call_args[0][1]

    @patch.object(bot, "get_power_level", return_value=75)
    @patch.object(bot, "reply")
    def test_role_rejects_invalid_role(self, mock_reply, mock_pl):
        bot.handle_command("!room:test", "@org:test", "!gov role @user superadmin")
        mock_reply.assert_called_once()
        assert "Unknown role" in mock_reply.call_args[0][1]

    @patch.object(bot, "get_power_level", return_value=75)
    @patch.object(bot, "reply")
    def test_role_organizer_requires_admin(self, mock_reply, mock_pl):
        bot.handle_command("!room:test", "@org:test", "!gov role @user organizer")
        mock_reply.assert_called_once()
        assert "admin" in mock_reply.call_args[0][1].lower()


class TestRevokeIsTerminal:
    """cmd_revoke must ban (not kick) every room the target is in — from the
    admin API, not just the static set — and lock the MAS account (F11/F12)."""

    def setup_method(self):
        bot.ROOM_IDS.clear()
        bot.ROOM_IDS.update({"general": "!g:test", "welcome": "!w:test"})
        bot.REPORT_DMS.clear()

    @patch.object(bot, "reply")
    @patch.object(bot, "send_message")
    @patch.object(bot, "append_vouch_jsonl")
    @patch.object(bot, "ban_user", return_value=True)
    @patch.object(bot.admin_client, "lock_account", return_value=True)
    @patch.object(bot.admin_client, "user_rooms", return_value=["!dyn:test", "!g:test"])
    def test_bans_union_of_rooms_and_locks(
        self, _ur, m_lock, m_ban, m_append, _send, _reply
    ):
        bot.REPORT_DMS["@mole:test"] = "!dm:test"
        bot.cmd_revoke(
            "!gov:test", "@op:test", ["@mole:test", "--reason", "compromised"]
        )
        # UNION: admin-enumerated (!dyn, !g) + static ROOM_IDS (!g, !w) + report DM (!dm)
        banned = {c.args[0] for c in m_ban.call_args_list}
        assert banned == {"!dyn:test", "!g:test", "!w:test", "!dm:test"}
        m_lock.assert_called_once_with("@mole:test")
        rec = m_append.call_args[0][0]
        assert rec["type"] == "revoked"
        assert rec["account_locked"] is True
        assert rec["rooms_banned"] == 4

    @patch.object(bot, "reply")
    @patch.object(bot, "send_message")
    @patch.object(bot, "append_vouch_jsonl")
    @patch.object(bot, "ban_user", return_value=True)
    @patch.object(bot.admin_client, "lock_account", return_value=False)
    @patch.object(bot.admin_client, "user_rooms", return_value=[])
    def test_lock_failure_is_surfaced_not_hidden(
        self, _ur, _lock, _ban, m_append, _send, m_reply
    ):
        bot.cmd_revoke("!gov:test", "@op:test", ["@mole:test", "--reason", "x"])
        assert "FAILED" in m_reply.call_args[0][1]
        assert m_append.call_args[0][0]["account_locked"] is False

    @patch.object(bot, "reply")
    def test_reason_required(self, m_reply):
        bot.cmd_revoke("!gov:test", "@op:test", ["@mole:test"])
        assert "reason" in m_reply.call_args[0][1].lower()


class TestDuress:
    """handle_duress: a member's own !duress panic self-locks their account,
    alerts organizers with a distinct msgtype, writes a durable canary record,
    and is honest when the lock fails — and can NEVER lock anyone but the
    sender, no matter what the message body says (duress-control)."""

    @patch.object(bot, "reply")
    @patch.object(bot, "send_message")
    @patch.object(bot, "append_vouch_jsonl")
    @patch.object(bot, "GOV_BOT_ROOM_ID", "!gov:test")
    @patch.object(bot.admin_client, "lock_account", return_value=True)
    def test_locks_sender_alerts_and_logs(self, m_lock, m_append, m_send, m_reply):
        bot.handle_duress("!dm:test", "@alice:test", "!duress")
        # locks the SENDER's own account
        m_lock.assert_called_once_with("@alice:test")
        # alerts organizers in #gov-bot with the distinct duress msgtype
        assert m_send.call_args.args[0] == "!gov:test"
        extra = m_send.call_args.kwargs["extra"]
        assert extra["msgtype"] == "org.rednet.alert.duress"
        assert extra["org.rednet.alert.duress"]["account"] == "@alice:test"
        assert extra["org.rednet.alert.duress"]["account_locked"] is True
        # durable, append-only evidence record
        rec = m_append.call_args[0][0]
        assert rec["type"] == "duress"
        assert rec["account"] == "@alice:test"
        assert rec["account_locked"] is True
        # calm confirmation to the DM
        assert "locked" in m_reply.call_args[0][1].lower()

    @patch.object(bot, "reply")
    @patch.object(bot, "send_message")
    @patch.object(bot, "append_vouch_jsonl")
    @patch.object(bot, "GOV_BOT_ROOM_ID", "!gov:test")
    @patch.object(bot.admin_client, "lock_account", return_value=True)
    def test_self_lock_only_ignores_body_target(self, m_lock, *_):
        # Even if the body names another user, only the SENDER is ever locked.
        # This is the anti-weaponization invariant: a spoofed/misfired signal
        # can lock nobody but whoever sent it.
        bot.handle_duress("!dm:test", "@alice:test", "!duress @victim:test")
        m_lock.assert_called_once_with("@alice:test")

    @patch.object(bot, "reply")
    @patch.object(bot, "send_message")
    @patch.object(bot, "append_vouch_jsonl")
    @patch.object(bot, "GOV_BOT_ROOM_ID", "!gov:test")
    @patch.object(bot.admin_client, "lock_account", return_value=False)
    def test_lock_failure_surfaced_with_manual_fallback(
        self, _lock, m_append, m_send, m_reply
    ):
        bot.handle_duress("!dm:test", "@bob:test", "!duress")
        # the organizer alert carries the manual mas-cli fallback, not a false OK
        alert = m_send.call_args.args[1]
        assert "FAILED" in alert
        assert "mas-cli manage lock-user bob" in alert
        # the canary record is honest about the failure
        assert m_append.call_args[0][0]["account_locked"] is False
        # the DM reply doesn't falsely claim the account is locked
        assert "did not go through" in m_reply.call_args[0][1]

    @patch.object(bot, "reply")
    @patch.object(bot, "send_message")
    @patch.object(bot, "append_vouch_jsonl")
    @patch.object(bot.admin_client, "lock_account")
    def test_ignores_bot_own_message(self, m_lock, m_append, m_send, m_reply):
        bot.handle_duress("!dm:test", bot.BOT_USER, "!duress")
        m_lock.assert_not_called()
        m_append.assert_not_called()

    @patch.object(bot, "reply")
    @patch.object(bot, "send_message")
    @patch.object(bot, "append_vouch_jsonl")
    @patch.object(bot.admin_client, "lock_account")
    def test_near_miss_token_no_op(self, m_lock, m_append, m_send, m_reply):
        # "!duressed" routes on the prefix but must NOT fire the self-lock.
        bot.handle_duress("!dm:test", "@alice:test", "!duressed by accident")
        m_lock.assert_not_called()
        m_append.assert_not_called()


class TestRoleManagedRoomsOnly:
    """cmd_role must not set power levels in rooms outside the managed set — a
    PL75 organizer could otherwise grant moderator PL server-wide via --rooms (F32)."""

    def setup_method(self):
        bot.ROOM_IDS.clear()
        bot.ROOM_IDS.update({"general": "!g:test"})

    @patch.object(
        bot,
        "read_vouch_jsonl",
        return_value=[
            {"type": "room", "room_id": "!dyn:test"},
            {"type": "vouch", "token_hash": "x"},
        ],
    )
    def test_managed_set_is_static_plus_created(self, _rv):
        assert bot.managed_room_ids() == {"!g:test", "!dyn:test"}

    @patch.object(bot, "append_vouch_jsonl")
    @patch.object(bot, "invite_user", return_value=True)
    @patch.object(bot, "set_power_level", return_value=True)
    @patch.object(bot, "resolve_alias", return_value="!evil:test")
    @patch.object(bot, "get_power_level", return_value=100)
    @patch.object(bot, "read_vouch_jsonl", return_value=[])
    @patch.object(bot, "reply")
    def test_role_rejects_unmanaged_room(self, m_reply, _rv, _pl, _ra, m_spl, _iv, _av):
        bot.cmd_role(
            "!gov:test", "@admin:test", ["@u:test", "moderator", "--rooms", "#evil"]
        )
        m_spl.assert_not_called()  # never touched the unmanaged room
        assert "unmanaged" in m_reply.call_args[0][1].lower()
