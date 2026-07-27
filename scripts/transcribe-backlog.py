#!/usr/bin/env python3
"""Warm the voice-note transcript cache so briefings can read audio as text.

Scans messages.db for voice notes in a lookback window, skips everything already
in transcripts.db, and transcribes the rest. Designed to run headless every
couple of hours (launchd), so the expensive part is done long before anyone asks
for a briefing.

Deliberately serial: faster-whisper is guarded by a process-wide model lock, so
concurrency buys no speed and only risks losing finished work to cache-write
contention. The model is loaded only when there is actually something to do —
an idle run costs a single SQL query.
"""

import argparse
import os
import sqlite3
import sys
import time
from datetime import datetime, timedelta

SERVER_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "whatsapp-mcp-server")
sys.path.insert(0, os.path.abspath(SERVER_DIR))

import transcription  # noqa: E402
from whatsapp import MESSAGES_DB_PATH  # noqa: E402


def log(msg: str) -> None:
    print(f"{datetime.now():%Y-%m-%d %H:%M:%S}  {msg}", flush=True)


def pending_voice_notes(hours: int) -> list[tuple[str, str, str]]:
    """Voice notes newer than `hours` that have no transcript yet."""
    # Timestamps are stored as local-time text with a UTC offset appended
    # ("2026-07-26 20:30:32+02:00"). Comparing the first 19 chars against a
    # plainly formatted cutoff keeps this a clean string compare — no offset or
    # microsecond noise to trip over.
    since = (datetime.now() - timedelta(hours=hours)).strftime("%Y-%m-%d %H:%M:%S")
    conn = sqlite3.connect(MESSAGES_DB_PATH, timeout=30)
    try:
        rows = conn.execute(
            """SELECT id, chat_jid, timestamp FROM messages
               WHERE media_type = 'audio' AND substr(timestamp, 1, 19) >= ?
                 AND deleted_at IS NULL
               ORDER BY timestamp""",
            (since,),
        ).fetchall()
    finally:
        conn.close()

    # The cache is the single source of truth for "already done" — checking it
    # per message is what makes overlapping runs and retries free.
    return [
        (mid, jid, ts)
        for mid, jid, ts in rows
        if transcription.get_cached_transcript(mid, jid) is None
    ]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hours", type=int, default=6,
                    help="lookback window; keep it well above the schedule interval so a "
                         "skipped or failed run is picked up by the next one (default: 6)")
    ap.add_argument("--limit", type=int, default=60,
                    help="max transcriptions per run, so one huge backlog cannot run away")
    args = ap.parse_args()

    try:
        pending = pending_voice_notes(args.hours)
    except sqlite3.Error as e:
        log(f"ERROR cannot read messages.db: {e}")
        return 1

    if not pending:
        log(f"nothing to do (window {args.hours}h)")
        return 0

    todo = pending[: args.limit]
    skipped = len(pending) - len(todo)
    log(f"{len(pending)} untranscribed voice note(s) in the last {args.hours}h"
        + (f", processing {len(todo)}, {skipped} deferred to next run" if skipped else ""))

    ok = failed = lost = 0
    t_start = time.time()
    for i, (mid, jid, ts) in enumerate(todo, 1):
        t0 = time.time()
        try:
            result = transcription.transcribe_message(mid, jid)
        except Exception as e:  # noqa: BLE001 - one bad file must not kill the run
            log(f"[{i}/{len(todo)}] {mid} EXCEPTION {e}")
            failed += 1
            continue

        if not result.get("success"):
            # Usually the bridge being down; the next run retries automatically.
            log(f"[{i}/{len(todo)}] {mid} FAILED {result.get('message')}")
            failed += 1
            continue

        ok += 1
        if result.get("cache_stored") is False:
            lost += 1
            log(f"[{i}/{len(todo)}] {mid} transcribed but CACHE WRITE LOST — will re-run")
        else:
            log(f"[{i}/{len(todo)}] {mid} ok ({len(result.get('text', ''))} chars, "
                f"{time.time() - t0:.1f}s)")

    log(f"done: {ok} transcribed, {failed} failed, {lost} cache writes lost, "
        f"{time.time() - t_start:.0f}s total")
    return 0 if failed == 0 and lost == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
