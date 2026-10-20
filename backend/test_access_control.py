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

def test_untrusted_tokens_cannot_create_new_rate_limit_buckets():
    guard = AccessControl({"GNARLY_REQUESTS_PER_MINUTE": "2", "GNARLY_REQUESTS_PER_DAY": "10"})
    assert guard.check("invented-a", "198.51.100.2", 1000) is None
    assert guard.check("invented-b", "198.51.100.2", 1001) is None
    assert guard.check("invented-c", "198.51.100.2", 1002)[0] == 429


def test_configured_allowlist_defaults_to_strict():
    guard = AccessControl({"GNARLY_ACCESS_TOKENS": "friend-a,friend-b"})
    assert guard.check(None, "198.51.100.3", 1000)[0] == 403
    assert guard.check("incorrect", "198.51.100.3", 1000)[0] == 403
    assert guard.check("friend-a", "198.51.100.3", 1000) is None


def test_strict_with_missing_allowlist_fails_closed():
    guard = AccessControl({"GNARLY_AUTH_MODE": "strict"})
    assert guard.check(None, "198.51.100.3", 1000)[0] == 503

def test_ticket_is_single_use_and_bound_to_video():
    guard = AccessControl({"GNARLY_ACCESS_TOKENS": "friend-a"})
    ticket, error = guard.issue_ticket("friend-a", "198.51.100.3", "abcdefghijk", now=1000)
    assert error is None
    assert ticket is not None
    assert guard.check_ticket(ticket, "198.51.100.3", "abcdefghijk", now=1001) is None
    assert guard.check_ticket(ticket, "198.51.100.3", "abcdefghijk", now=1002)[0] == 403


def test_ticket_rejects_wrong_track_expiry_and_invalid_token():
    guard = AccessControl({"GNARLY_ACCESS_TOKENS": "friend-a"})
    ticket, error = guard.issue_ticket("wrong", "198.51.100.3", "abcdefghijk", now=1000)
    assert ticket is None
    assert error[0] == 403
    ticket, error = guard.issue_ticket("friend-a", "198.51.100.3", "abcdefghijk", now=1000)
    assert guard.check_ticket(ticket, "198.51.100.3", "other_video", now=1001)[0] == 403
    second, error = guard.issue_ticket("friend-a", "198.51.100.3", "abcdefghijk", now=1002)
    assert guard.check_ticket(second, "198.51.100.3", "abcdefghijk", now=1200)[0] == 403
