#!/usr/bin/env bash
# Backward-compatible Claude Code entrypoint. The implementation is shared with
# Codex because both runtimes use the same SessionStart additionalContext shape.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/sessionstart-compact.sh"
