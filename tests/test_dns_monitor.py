"""Tests for dns_monitor.py analysis logic (no tcpdump or network required)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

# Reset sliding-window state before each test
import dns_monitor as dm
import pytest


@pytest.fixture(autouse=True)
def _reset_state():
    dm._txt_hits.clear()
    dm._sub_hits.clear()
    yield


# ── shannon_entropy ────────────────────────────────────────────────────────────

def test_entropy_empty():
    assert dm.shannon_entropy("") == 0.0


def test_entropy_constant():
    # All same character → 0 entropy
    assert dm.shannon_entropy("aaaa") == 0.0


def test_entropy_binary():
    # Two equally frequent chars → 1.0 bit
    assert abs(dm.shannon_entropy("ababab") - 1.0) < 0.01


def test_entropy_base32_like():
    # Base32-encoded data has high entropy
    label = "jf3k2ma9bc4xz7wp"   # looks like base32
    ent = dm.shannon_entropy(label)
    assert ent >= 3.0


def test_entropy_normal_word():
    # Normal hostname component has lower entropy
    assert dm.shannon_entropy("myserver") < 3.5


# ── analyze_query: normal queries pass ────────────────────────────────────────

def test_normal_a_query():
    assert dm.analyze_query("example.com.", "A") is None


def test_normal_subdomain():
    assert dm.analyze_query("api.example.com.", "A") is None


def test_single_label_ignored():
    assert dm.analyze_query("localhost", "A") is None


def test_low_entropy_short_label():
    # Short label below MIN_LABEL_LEN — entropy check skipped
    assert dm.analyze_query("abc.example.com.", "A") is None


# ── analyze_query: long label ──────────────────────────────────────────────────

def test_long_label_flagged():
    long = "a" * dm.LABEL_LEN_LIMIT
    result = dm.analyze_query(f"{long}.attacker.com.", "A")
    assert result is not None
    assert "long DNS label" in result


def test_label_just_under_limit():
    label = "a" * (dm.LABEL_LEN_LIMIT - 1)
    # Should not be flagged for length (may be flagged for entropy if long enough)
    result = dm.analyze_query(f"{label}.example.com.", "A")
    # Not flagged for length
    if result:
        assert "long DNS label" not in result


# ── analyze_query: high entropy label ────────────────────────────────────────

def test_high_entropy_base64_label():
    # 21-char base64-looking string (all unique chars → entropy ≈ 4.4 bits/char)
    label = "aB3kP9xQ2mR7tY5wZ1nV"  # 21 unique chars → very high entropy
    assert len(label) >= dm.MIN_LABEL_LEN
    result = dm.analyze_query(f"{label}.attacker.com.", "A")
    assert result is not None
    assert "entropy" in result


def test_high_entropy_short_label_ignored():
    # Only 10 chars — below MIN_LABEL_LEN, skipped
    label = "aB3kP9xQ2m"
    result = dm.analyze_query(f"{label}.example.com.", "A")
    assert result is None


def test_low_entropy_label_not_flagged():
    # 25 chars but all the same → entropy 0
    label = "a" * 25
    result = dm.analyze_query(f"{label}.example.com.", "A")
    # Might be flagged for length, but NOT entropy
    if result:
        assert "entropy" not in result


# ── analyze_query: TXT flood ──────────────────────────────────────────────────

def test_single_txt_not_flagged():
    result = dm.analyze_query("example.com.", "TXT")
    assert result is None


def test_txt_flood_flagged():
    parent = "attacker.com"
    for i in range(dm.TXT_FLOOD_COUNT - 1):
        assert dm.analyze_query(f"sub{i}.{parent}.", "TXT") is None
    # The threshold-th query should trigger
    result = dm.analyze_query(f"sub_final.{parent}.", "TXT")
    assert result is not None
    assert "TXT" in result


def test_txt_flood_different_domains_isolated():
    # Flooding one domain must not affect another
    for i in range(dm.TXT_FLOOD_COUNT - 1):
        dm.analyze_query(f"sub{i}.evil.com.", "TXT")
    # Clean domain should still be fine
    assert dm.analyze_query("legit.org.", "TXT") is None


# ── analyze_query: subdomain flood ───────────────────────────────────────────

def test_subdomain_flood_flagged():
    parent = "tunnel.attacker.com"
    for i in range(dm.SUBDOMAIN_FLOOD_COUNT - 1):
        result = dm.analyze_query(f"chunk{i}.{parent}.", "A")
        assert result is None or "subdomain flood" not in result
    result = dm.analyze_query(f"chunk_final.{parent}.", "A")
    assert result is not None
    assert "subdomain flood" in result


def test_subdomain_flood_deduplicates():
    # Sending the same subdomain repeatedly must NOT count as unique entries
    parent = "tunnel.attacker.com"
    for _ in range(dm.SUBDOMAIN_FLOOD_COUNT + 5):
        dm.analyze_query(f"same.{parent}.", "A")
    # Only 1 unique subdomain — should not trigger
    result = dm.analyze_query(f"same.{parent}.", "A")
    assert result is None or "subdomain flood" not in result


def test_no_flood_for_two_label_domain():
    # Queries directly to a root domain (e.g. evil.com) don't trigger subdomain flood
    for _ in range(dm.SUBDOMAIN_FLOOD_COUNT + 5):
        dm.analyze_query("evil.com.", "A")
    # len(labels) == 2 → flood check skipped
    assert dm.analyze_query("evil.com.", "A") is None


# ── _LINE_RE parser ───────────────────────────────────────────────────────────

def test_line_re_matches_query():
    line = "13:06:15.706491 IP 192.168.1.100.54123 > 8.8.8.8.53: 12345+ A? example.com. (28)"
    m = dm._LINE_RE.search(line)
    assert m is not None
    assert m.group(1).upper() == "A"
    assert m.group(2) == "example.com."


def test_line_re_matches_txt():
    line = "13:07:00.000000 IP 10.0.0.1.5555 > 1.1.1.1.53: 999+ TXT? evil.attacker.com. (42)"
    m = dm._LINE_RE.search(line)
    assert m is not None
    assert m.group(1).upper() == "TXT"
    assert m.group(2) == "evil.attacker.com."


def test_line_re_ignores_response():
    # Response has src port 53 on the LEFT of >, not the right
    line = "13:06:15.810234 IP 8.8.8.8.53 > 192.168.1.100.54123: 12345 1/0/0 A 93.184.216.34 (44)"
    m = dm._LINE_RE.search(line)
    assert m is None


def test_line_re_ignores_non_dns():
    line = "13:06:15.000000 IP 192.168.1.1.443 > 10.0.0.1.54000: Flags [S], seq 0"
    m = dm._LINE_RE.search(line)
    assert m is None
