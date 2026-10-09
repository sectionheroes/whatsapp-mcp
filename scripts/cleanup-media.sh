#!/bin/bash
# Deletes downloaded WhatsApp media (images, videos, stickers/WebP) older than
# MAX_AGE_DAYS from the bridge store.
#
# Audio and documents are deliberately kept: voice notes are still needed by
# scripts/transcribe-backlog.py until they have been transcribed, and documents
# are small enough not to matter. Anything deleted here is re-fetched on demand
# by the download_media MCP tool, so this is a cache eviction, not data loss.
#
# Runs every 3 days via the com.whatsapp-mcp.media-cleanup LaunchAgent
# installed by scripts/install-launchd-macos.sh.
#
# Environment:
#   WHATSAPP_MCP_STORE_DIR          store directory (default: <repo>/whatsapp-bridge/store)
#   WHATSAPP_BRIDGE_DIR             bridge directory, used to derive the store
#   WHATSAPP_MCP_MEDIA_MAX_AGE_DAYS age threshold in days (default: 3)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

STORE="${WHATSAPP_MCP_STORE_DIR:-${WHATSAPP_BRIDGE_DIR:-$REPO_ROOT/whatsapp-bridge}/store}"
MAX_AGE_DAYS="${WHATSAPP_MCP_MEDIA_MAX_AGE_DAYS:-3}"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

if [[ ! -d "$STORE" ]]; then
  echo "$(timestamp) cleanup-media: store directory not found: $STORE" >&2
  exit 1
fi

if ! [[ "$MAX_AGE_DAYS" =~ ^[0-9]+$ ]]; then
  echo "$(timestamp) cleanup-media: MAX_AGE_DAYS must be a non-negative integer, got: $MAX_AGE_DAYS" >&2
  exit 1
fi

deleted="$(find "$STORE" -type f \
  \( -name 'image_*' -o -name 'video_*' -o -name 'sticker_*' \) \
  -mtime +"$MAX_AGE_DAYS" -print -delete | wc -l | tr -d ' ')" || true

echo "$(timestamp) cleanup-media: deleted ${deleted:-0} file(s) older than $MAX_AGE_DAYS day(s) (images/videos/stickers) from $STORE"
