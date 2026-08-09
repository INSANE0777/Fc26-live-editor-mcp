"""Tests for FC26 career-save support in fifa_squad.py / mcp_server.py.

Unit tests need no game files. Integration test parses a real career save
when the FC26_TEST_CAREER env var points to one (skipped otherwise).
"""
import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from fc26_mcp.fifa_squad import (
    SquadFile,
    FBCHUNKS,
    career_overview,
    detect_save_type,
    find_career_files,
)

LE = "<"
FBCHUNKS_MAGIC = b"FBCHUNKS\x01\x00"


def _fake_fbchunks(save_type: str) -> bytes:
    """Minimal FBCHUNKS file: 10-byte magic, size, name, 102-byte-ish header,
    SaveType string at offset 1126, then a DB header."""
    body = (
        FBCHUNKS_MAGIC
        + struct.pack("<I", 0)  # size field, patched later
        + b"XABI\x00\x00\x00\x00"
        + b"\x00" * (1126 - 26)
        + save_type.encode() + b"\x00"
    )
    # append a DB section (valid magic + size)
    db = b"\x44\x42\x00\x08\x00\x00\x00\x00" + struct.pack("<I", 8)
    raw = body + b"\x00" * (2048 - len(body)) + db
    raw = raw[:14] + struct.pack("<I", len(raw) - 1126) + raw[18:]
    return raw


def make_fake_career():
    return b"FBCHUNKS\x01\x00" + b"\x00" * (1126 - 10) + b"SaveType_Career\x00"


def test_detect_save_type_magic_check(tmp_path):
    good = tmp_path / "good"
    good.write_bytes(make_fake_career())
    assert detect_save_type(good) == "career"

    squad = tmp_path / "sq"
    squad.write_bytes(b"FBCHUNKS\x01\x00" + b"\x00" * (1126 - 10) + b"SaveType_Squads\x00")
    assert detect_save_type(squad) == "squad"

    junk = tmp_path / "junk"
    junk.write_bytes(b"NOTFBCHUNKS")
    assert detect_save_type(junk) is None


def test_find_career_files(tmp_path):
    (tmp_path / "CmMgrC20260101120000").write_bytes(b"x")
    (tmp_path / "SquadsFoo").write_bytes(b"y")
    found = sorted(Path(f).name for f in find_career_files(str(tmp_path)))
    assert found == ["CmMgrC20260101120000"]


@pytest.mark.skipif(
    not os.environ.get("FC26_TEST_CAREER"),
    reason="set FC26_TEST_CAREER to a CmMgrC* path to run career integration tests",
)
def test_career_integration(tmp_path):
    src = Path(os.environ["FC26_TEST_CAREER"])
    meta = Path(__file__).parents[1] / "src" / "fc26_mcp" / "data" / "fifa_ng_db-meta-fc26.xml"
    sq = SquadFile(str(src), str(meta))
    names = {m["name"] for m in sq.tables_meta if m["name"]}
    assert "career_users" in names
    assert "teamplayerlinks" not in names  # career files have no squad tables
    assert len(names) >= 30

    ov = career_overview(sq)
    user = ov["user"]
    assert user["usertype"] in (0, 1)
    assert ov["contracts"] >= 0

    # round-trip: reparse a clone to make sure editing a field still parses
    clone = tmp_path / "clone_career"
    sq.save(str(clone))
    sq2 = SquadFile(clone, meta)
    assert sq2._parse_table("career_users")[1]  # fields parse