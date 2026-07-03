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
