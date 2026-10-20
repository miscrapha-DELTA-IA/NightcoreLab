from access_control import AccessControl


def test_permissive_old_build_and_per_user_limits():
    guard = AccessControl({"GNARLY_REQUESTS_PER_MINUTE": "2", "GNARLY_REQUESTS_PER_DAY": "3"})
    assert guard.check(None, "127.0.0.1", 1000) is None
    assert guard.check(None, "127.0.0.1", 1001) is None
    assert guard.check(None, "127.0.0.1", 1002)[0] == 429
    assert guard.check(None, "127.0.0.2", 1002) is None
    assert guard.check(None, "127.0.0.1", 1062) is None
    assert guard.check(None, "127.0.0.1", 1063)[0] == 429


def test_strict_token_and_query_header_equivalence():
    guard = AccessControl({"GNARLY_AUTH_MODE": "strict", "GNARLY_ACCESS_TOKENS": "alice,bob"})
    assert guard.check(None, "same-ip", 1000)[0] == 403
    assert guard.check("bad", "same-ip", 1000)[0] == 403
    assert guard.check("alice", "same-ip", 1000) is None
    assert guard.check("bob", "same-ip", 1000) is None


def test_daily_window_expires():
    guard = AccessControl({"GNARLY_REQUESTS_PER_DAY": "1"})
    assert guard.check(None, "x", 0) is None
    assert guard.check(None, "x", 1)[0] == 429
    assert guard.check(None, "x", 86401) is None
