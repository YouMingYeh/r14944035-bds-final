"""anonymize.py — the PII gate.

Everything that leaves the local Postgres for the repo/report/dashboard must be an
aggregate. This module fails loudly if any per-player identifier (uuid) or email slips
into the serialized output, so we can never accidentally commit production PII.
"""
from __future__ import annotations
import json
import re

_UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
_EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


def assert_no_pii(obj) -> None:
    """Raise if the object's JSON contains a uuid or email. Aggregates only."""
    blob = json.dumps(obj, ensure_ascii=False)
    for name, rx in (("uuid", _UUID), ("email", _EMAIL)):
        m = rx.search(blob)
        if m:
            raise ValueError(f"PII gate: found {name}-like value in output: {m.group(0)!r}")
