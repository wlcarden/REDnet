"""Tests for the REDnet room creation policy module.

Synapse is not installed in CI — stub the two imports the module needs, then
exercise the pure decision functions (is_dm_shaped, may_create).
"""

import os
import sys
import types

# Stub synapse.module_api before importing the module under test.
_module_api = types.ModuleType("synapse.module_api")
_module_api.ModuleApi = object
_errors = types.ModuleType("synapse.module_api.errors")


class _StubSynapseError(Exception):
    def __init__(self, code, msg, errcode=None):
        super().__init__(msg)
        self.code = code
        self.msg = msg
        self.errcode = errcode


class _StubCodes:
    FORBIDDEN = "M_FORBIDDEN"


_errors.SynapseError = _StubSynapseError
_errors.Codes = _StubCodes
_module_api.errors = _errors
sys.modules.setdefault("synapse", types.ModuleType("synapse"))
sys.modules["synapse.module_api"] = _module_api
sys.modules["synapse.module_api.errors"] = _errors

sys.path.insert(0, os.path.dirname(__file__))
import rednet_room_policy as policy

ALLOWED = {"@rednet-system:test", "@rednet-gov:test", "@rednet-mod:test"}


class TestDmShape:
    def test_element_dm_allowed(self):
        # What Element sends when a member starts a direct chat.
        assert policy.is_dm_shaped(
            {
                "is_direct": True,
                "preset": "trusted_private_chat",
                "invite": ["@friend:test"],
            }
        )

    def test_dm_without_invite_allowed(self):
        assert policy.is_dm_shaped({"is_direct": True, "preset": "private_chat"})

    def test_plain_room_rejected(self):
        assert not policy.is_dm_shaped({"name": "my room", "preset": "private_chat"})

    def test_dm_with_alias_rejected(self):
        assert not policy.is_dm_shaped(
            {"is_direct": True, "room_alias_name": "general2"}
        )

    def test_dm_with_multiple_invites_rejected(self):
        assert not policy.is_dm_shaped(
            {"is_direct": True, "invite": ["@a:test", "@b:test"]}
        )

    def test_dm_with_public_preset_rejected(self):
        assert not policy.is_dm_shaped({"is_direct": True, "preset": "public_chat"})

    def test_space_disguised_as_dm_rejected(self):
        assert not policy.is_dm_shaped(
            {"is_direct": True, "creation_content": {"type": "m.space"}}
        )

    def test_empty_request_rejected(self):
        assert not policy.is_dm_shaped({})


class TestMayCreate:
    def test_system_account_creates_anything(self):
        assert policy.may_create(
            "@rednet-system:test", {"name": "any room"}, False, ALLOWED
        )

    def test_gov_bot_creates_anything(self):
        assert policy.may_create(
            "@rednet-gov:test",
            {"creation_content": {"type": "m.space"}},
            False,
            ALLOWED,
        )

    def test_synapse_admin_creates_anything(self):
        assert policy.may_create("@operator:test", {"name": "room"}, True, ALLOWED)

    def test_member_denied_shared_room(self):
        assert not policy.may_create("@member:test", {"name": "room"}, False, ALLOWED)

    def test_member_denied_space(self):
        assert not policy.may_create(
            "@member:test",
            {"creation_content": {"type": "m.space"}},
            False,
            ALLOWED,
        )

    def test_member_allowed_dm(self):
        assert policy.may_create(
            "@member:test",
            {
                "is_direct": True,
                "preset": "trusted_private_chat",
                "invite": ["@x:test"],
            },
            False,
            ALLOWED,
        )

    def test_member_denied_alias_squat(self):
        assert not policy.may_create(
            "@member:test",
            {"is_direct": True, "room_alias_name": "general2"},
            False,
            ALLOWED,
        )


class TestModuleInit:
    def test_empty_allowlist_raises(self):
        # An empty allowlist would brick bootstrap — must fail at startup.
        import pytest

        class FakeApi:
            def register_third_party_rules_callbacks(self, **kw):
                pass

        with pytest.raises(ValueError):
            policy.RednetRoomPolicy({}, FakeApi())

    def test_valid_config_registers_callback(self):
        registered = {}

        class FakeApi:
            def register_third_party_rules_callbacks(self, **kw):
                registered.update(kw)

        policy.RednetRoomPolicy({"allowed_creators": list(ALLOWED)}, FakeApi())
        assert "on_create_room" in registered
