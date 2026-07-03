"""Tests for admin_client — the gov-bot's calls into the isolated admin services.

Locks down that privileged ops go to the right service with the shared secret,
and that failures are surfaced (not swallowed into a false success), so the F2
isolation can't silently regress into the bot calling admin APIs directly.
"""

import os
import sys
from unittest.mock import MagicMock, patch

os.environ.setdefault("SYNMIN_SVC_SECRET", "syn-secret")
os.environ.setdefault("MINT_SVC_SECRET", "mint-secret")

sys.path.insert(0, os.path.dirname(__file__))
import admin_client as ac


def _resp(status, payload):
    r = MagicMock()
    r.status_code = status
    r.json.return_value = payload
    return r


class TestPurgeRoom:
    def test_posts_to_synmin_with_secret(self):
        with patch.object(
            ac.http, "post", return_value=_resp(200, {"delete_id": "d1"})
        ) as p:
            st, d = ac.purge_room("!r:test")
        assert st == 200 and d["delete_id"] == "d1"
        assert p.call_args[0][0].endswith("/purge-room")
        assert p.call_args.kwargs["headers"]["X-Synmin-Secret"] == ac.SYNMIN_SVC_SECRET
        assert p.call_args.kwargs["json"] == {"room_id": "!r:test"}


class TestListRooms:
    def test_gets_with_limit_and_secret(self):
        with patch.object(
            ac.http, "get", return_value=_resp(200, {"rooms": [], "total_rooms": 0})
        ) as g:
            st, _d = ac.list_rooms(500)
        assert st == 200
        assert g.call_args[0][0].endswith("/rooms")
        assert g.call_args.kwargs["params"] == {"limit": 500}
        assert g.call_args.kwargs["headers"]["X-Synmin-Secret"] == ac.SYNMIN_SVC_SECRET


class TestUserRooms:
    def test_returns_joined_rooms(self):
        with patch.object(
            ac.http, "get", return_value=_resp(200, {"joined_rooms": ["!a", "!b"]})
        ):
            assert ac.user_rooms("@u:test") == ["!a", "!b"]

    def test_empty_on_non_200(self):
        # a degraded synmin-svc must not silently claim the user is in NO rooms in
        # a way that reads as success — the caller unions with other sources.
        with patch.object(
            ac.http, "get", return_value=_resp(403, {"error": "forbidden"})
        ):
            assert ac.user_rooms("@u:test") == []


class TestLockAccount:
    def test_true_on_locked(self):
        with patch.object(
            ac.http, "post", return_value=_resp(200, {"locked": True, "user_id": "01K"})
        ) as p:
            assert ac.lock_account("@u:test") is True
        assert p.call_args[0][0].endswith("/lock")
        assert p.call_args.kwargs["headers"]["X-Mint-Secret"] == ac.MINT_SVC_SECRET
        assert p.call_args.kwargs["json"] == {"user": "@u:test"}

    def test_false_on_non_200(self):
        with patch.object(
            ac.http, "post", return_value=_resp(502, {"error": "lock_failed"})
        ):
            assert ac.lock_account("@u:test") is False

    def test_false_when_locked_flag_absent(self):
        with patch.object(ac.http, "post", return_value=_resp(200, {})):
            assert ac.lock_account("@u:test") is False

    def test_false_on_exception(self):
        with patch.object(ac.http, "post", side_effect=OSError("boom")):
            assert ac.lock_account("@u:test") is False
