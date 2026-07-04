"""Tests for the in-client minting endpoint's security-critical gating.

The full request path is verified end-to-end against a live stack; these lock
down the auth decisions (OpenID verification, organizer PL gate) and the
mint/vouch orchestration so a regression can't silently open minting up.
"""

import os
import sys
from unittest.mock import MagicMock, patch

os.environ.setdefault("REDNET_DOMAIN", "test.example")
os.environ.setdefault("GOV_BOT_TOKEN", "fake-bot-token")
os.environ.setdefault("SYS_TOKEN", "fake-sys-token")
os.environ.setdefault("REDNET_ACCESS_URL", "http://synapse:8008")
os.environ.setdefault("MINT_SVC_SECRET", "fake-mint-secret")

sys.path.insert(0, os.path.dirname(__file__))
import bot
import mint_endpoint as me


def _resp(status, payload):
    r = MagicMock()
    r.status_code = status
    r.json.return_value = payload
    return r


class TestVerifyOpenID:
    def test_valid_token_returns_mxid(self):
        with patch.object(me.http, "get", return_value=_resp(200, {"sub": "@op:test"})):
            assert me.verify_openid("tok") == "@op:test"

    def test_empty_token_is_none(self):
        assert me.verify_openid("") is None
        assert me.verify_openid(None) is None

    def test_non_200_is_none(self):
        with patch.object(me.http, "get", return_value=_resp(401, {})):
            assert me.verify_openid("tok") is None

    def test_network_error_is_none(self):
        with patch.object(me.http, "get", side_effect=OSError("boom")):
            assert me.verify_openid("tok") is None


class TestOrganizerGate:
    def setup_method(self):
        bot.ROOM_IDS["governance"] = "!gov:test"

    @patch.object(bot, "get_power_level", return_value=75)
    def test_organizer_pl75_allowed(self, _pl):
        assert me.is_organizer("@org:test") is True

    @patch.object(bot, "get_power_level", return_value=100)
    def test_admin_allowed(self, _pl):
        assert me.is_organizer("@admin:test") is True

    @patch.object(bot, "get_power_level", return_value=50)
    def test_moderator_denied(self, _pl):
        assert me.is_organizer("@mod:test") is False

    @patch.object(bot, "get_power_level", return_value=0)
    def test_member_denied(self, _pl):
        assert me.is_organizer("@member:test") is False

    def test_no_governance_room_denies(self):
        bot.ROOM_IDS.pop("governance", None)
        assert me.is_organizer("@op:test") is False

    def test_no_mxid_denies(self):
        assert me.is_organizer(None) is False


class TestMintCall:
    def test_returns_token_and_expiry(self):
        with patch.object(
            me.http,
            "post",
            return_value=_resp(200, {"token": "T", "expires_at": "2026-07-09"}),
        ):
            assert me.call_mint(604800) == ("T", "2026-07-09")

    def test_missing_token_raises(self):
        import pytest

        with patch.object(me.http, "post", return_value=_resp(200, {"error": "x"})):
            with pytest.raises(RuntimeError):
                me.call_mint(604800)


class TestVouchIsHashOnly:
    @patch.object(bot, "append_vouch_jsonl")
    def test_records_hash_not_token(self, mock_append):
        bot.ROOM_IDS.pop(
            "vouch-log", None
        )  # skip the room post, just check the index record
        h, posted = me.record_vouch("SECRET-TOKEN-VALUE", "@op:test", "Maria")
        rec = mock_append.call_args[0][0]
        assert rec["type"] == "vouch"
        assert rec["voucher"] == "@op:test"
        assert "token_hash" in rec
        # the raw token must never appear in the recorded vouch
        assert "SECRET-TOKEN-VALUE" not in str(rec)
        assert rec["source"] == "in-client"
        # no vouch-log room resolved → the post could not land, must report False
        assert posted is False
        assert h == rec["token_hash"]


class TestVouchRecordedFlag:
    """The vouch-log post must not be silently swallowed: record_vouch reports
    whether the room-visible provenance event actually landed (F25)."""

    @patch.object(bot, "append_vouch_jsonl")
    def test_posted_true_when_event_id_returned(self, _append):
        bot.ROOM_IDS["vouch-log"] = "!vl:test"
        with patch.object(me.http, "put", return_value=_resp(200, {"event_id": "$e"})):
            _h, posted = me.record_vouch("tok", "@op:test", "Maria")
        assert posted is True

    @patch.object(bot, "append_vouch_jsonl")
    def test_posted_false_when_no_event_id(self, _append):
        bot.ROOM_IDS["vouch-log"] = "!vl:test"
        with patch.object(
            me.http, "put", return_value=_resp(500, {"errcode": "M_UNKNOWN"})
        ):
            _h, posted = me.record_vouch("tok", "@op:test", "Maria")
        assert posted is False

    @patch.object(bot, "append_vouch_jsonl")
    def test_posted_false_on_network_error(self, _append):
        bot.ROOM_IDS["vouch-log"] = "!vl:test"
        with patch.object(me.http, "put", side_effect=OSError("boom")):
            _h, posted = me.record_vouch("tok", "@op:test", "Maria")
        assert posted is False


class TestVouchServeAuth:
    """/governance/data/vouch.jsonl must require a valid Matrix OpenID token — it was
    previously served UNAUTHENTICATED (whole trust-graph leak to untrusted networks).
    Any authenticated member is allowed (matches the all-members provenance UI)."""

    def _run(self, auth):
        h = me.Handler.__new__(me.Handler)
        h.headers = {"Authorization": auth} if auth is not None else {}
        h.path = "/governance/data/vouch.jsonl"
        h.wfile = MagicMock()
        sent = {}
        h.send_response = lambda c: sent.__setitem__("status", c)
        h.send_header = lambda *a: None
        h.end_headers = lambda: None
        h._json = lambda c, o: sent.update(status=c, json=o)
        me.Handler.do_GET(h)
        sent["wfile"] = h.wfile
        return sent

    def test_no_auth_header_401(self):
        assert self._run(None)["status"] == 401

    def test_non_bearer_scheme_401(self):
        assert self._run("Basic abc")["status"] == 401

    def test_invalid_token_401(self):
        with patch.object(me, "verify_openid", return_value=None):
            assert self._run("Bearer bad")["status"] == 401

    def test_valid_member_token_serves_graph(self, tmp_path):
        f = tmp_path / "vouch.jsonl"
        f.write_bytes(b'{"type":"claimed","account":"@a:test","voucher":"@v:test"}\n')
        with (
            patch.object(me, "verify_openid", return_value="@member:test"),
            patch.object(me.bot, "VOUCH_PATH", str(f)),
        ):
            sent = self._run("Bearer good")
        assert sent["status"] == 200
        sent["wfile"].write.assert_called_once()
        assert b"@v:test" in sent["wfile"].write.call_args[0][0]
