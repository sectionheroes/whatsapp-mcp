"""Local voice-message transcription via faster-whisper.

Runs entirely on this machine: audio never leaves the host. The model is
downloaded once from Hugging Face on first use and cached locally
(~/.cache/huggingface). Model size is configurable via WHISPER_MODEL
(tiny/base/small/medium/large-v3); "medium" is the default because voice
notes here are mostly German and the smaller models degrade noticeably on
non-English audio.
"""

import os
import sqlite3
import sys
import threading

_model = None
_model_lock = threading.Lock()


def _transcripts_db_path() -> str:
    """Transcript cache lives next to messages.db but in its own file, so bridge
    schema migrations can never collide with it."""
    from whatsapp import MESSAGES_DB_PATH

    return os.getenv(
        "WHATSAPP_TRANSCRIPTS_DB",
        os.path.join(os.path.dirname(MESSAGES_DB_PATH), "transcripts.db"),
    )


def _transcripts_conn() -> sqlite3.Connection:
    # WAL + a generous busy timeout: the MCP server and the backlog job can write
    # concurrently, and a lost write is expensive here — the audio counts as
    # never transcribed and gets re-run on the next pass.
    conn = sqlite3.connect(_transcripts_db_path(), timeout=60)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=60000")
    conn.execute(
        """CREATE TABLE IF NOT EXISTS transcripts (
            message_id TEXT NOT NULL,
            chat_jid TEXT NOT NULL,
            text TEXT NOT NULL,
            language TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (message_id, chat_jid)
        )"""
    )
    return conn


def get_cached_transcript(message_id: str, chat_jid: str) -> str | None:
    try:
        with _transcripts_conn() as conn:
            row = conn.execute(
                "SELECT text FROM transcripts WHERE message_id = ? AND chat_jid = ?",
                (message_id, chat_jid),
            ).fetchone()
            return row[0] if row else None
    except sqlite3.Error as e:
        print(f"[transcription] cache read failed for {message_id}: {e}", file=sys.stderr)
        return None


def _store_transcript(message_id: str, chat_jid: str, text: str, language: str | None) -> bool:
    """Persist a finished transcript. Returns False if the write was lost.

    Never fail silently: a dropped write costs a full re-transcription later, so
    the caller (and the logs) need to know it happened.
    """
    try:
        with _transcripts_conn() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO transcripts (message_id, chat_jid, text, language)"
                " VALUES (?, ?, ?, ?)",
                (message_id, chat_jid, text, language),
            )
        return True
    except sqlite3.Error as e:
        print(f"[transcription] cache write failed for {message_id}: {e}", file=sys.stderr)
        return False


def transcribe_message(message_id: str, chat_jid: str, language: str | None = None) -> dict:
    """Cache-aware transcription of a voice message: returns the cached text when
    available, otherwise downloads the media via the bridge and transcribes it."""
    cached = get_cached_transcript(message_id, chat_jid)
    if cached is not None:
        return {"success": True, "text": cached, "cached": True}

    from whatsapp import download_media

    file_path = download_media(message_id, chat_jid)
    if not file_path:
        return {"success": False, "message": "Failed to download voice message media"}

    result = transcribe_file(file_path, language=language)
    if result.get("success"):
        result["file_path"] = file_path
        result["cached"] = False
        result["cache_stored"] = _store_transcript(
            message_id, chat_jid, result["text"], result.get("language")
        )
    return result


def annotate_audio_messages(messages: list, max_new_transcriptions: int = 5) -> list:
    """Attach transcripts to audio messages in a list_messages result.

    Cached transcripts are always attached. At most `max_new_transcriptions`
    uncached voice notes are transcribed on the fly (newest first, i.e. list
    order) so a large history page cannot stall the tool call for minutes.
    """
    fresh_used = 0
    for msg in messages:
        if not isinstance(msg, dict) or msg.get("media_type") != "audio":
            continue
        message_id, chat_jid = msg.get("id"), msg.get("chat_jid")
        if not message_id or not chat_jid:
            continue

        text = get_cached_transcript(message_id, chat_jid)
        if text is None:
            if fresh_used >= max_new_transcriptions:
                msg["transcription"] = None
                msg["transcription_note"] = (
                    "Not transcribed (per-call limit reached); use transcribe_voice_message"
                )
                continue
            fresh_used += 1
            result = transcribe_message(message_id, chat_jid)
            if not result.get("success"):
                msg["transcription"] = None
                msg["transcription_note"] = result.get("message", "Transcription failed")
                continue
            text = result["text"]

        msg["transcription"] = text
        if not msg.get("content"):
            msg["content"] = f"[Sprachnachricht] {text}"
    return messages


def _get_model():
    global _model
    with _model_lock:
        if _model is None:
            from faster_whisper import WhisperModel

            model_size = os.getenv("WHISPER_MODEL", "medium")
            # int8 keeps memory modest and is the fastest CPU path on Apple Silicon
            _model = WhisperModel(model_size, device="cpu", compute_type="int8")
        return _model


def transcribe_file(file_path: str, language: str | None = None) -> dict:
    """Transcribe an audio file and return text plus metadata.

    Args:
        file_path: Path to the audio file (WhatsApp .ogg voice notes work directly).
        language: Optional ISO language code (e.g. "de"); autodetected when None.
    """
    if not os.path.isfile(file_path):
        return {"success": False, "message": f"Audio file not found: {file_path}"}

    try:
        model = _get_model()
        segments, info = model.transcribe(
            file_path,
            language=language,
            vad_filter=True,
        )
        text = " ".join(segment.text.strip() for segment in segments).strip()
        return {
            "success": True,
            "text": text,
            "language": info.language,
            "language_probability": round(info.language_probability, 3),
            "duration_seconds": round(info.duration, 1),
        }
    except Exception as e:  # noqa: BLE001 - surface any backend failure to the tool caller
        return {"success": False, "message": f"Transcription failed: {e}"}
