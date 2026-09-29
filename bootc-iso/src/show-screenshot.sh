#!/usr/bin/bash
# Display a PPM screendump inline in terminals that support it.
# Usage: show-screenshot.sh <ppm-path> <label>
#
# Supported terminals:
#   Kitty  — uses kitten icat
#   iTerm2 — uses the iTerm2 inline image protocol (ESC]1337;File=...)
#   Others — prints the path only

set -euo pipefail
PPM="${1:-}"
LABEL="${2:-Screenshot}"

[[ -f "$PPM" ]] || exit 0

echo ""
echo "── ${LABEL} ──────────────────────────────"

if command -v kitty &>/dev/null 2>&1; then
    kitty +kitten icat --align left "$PPM" 2>/dev/null || true
elif [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]]; then
    python3 - "$PPM" <<'PYEOF'
import base64, sys
data = open(sys.argv[1], 'rb').read()
b64 = base64.b64encode(data).decode()
print(f'\033]1337;File=inline=1;width=80;preserveAspectRatio=1:{b64}\a',
      end='', flush=True)
PYEOF
else
    echo "(Kitty or iTerm2 required for inline display)"
    echo "Screenshot: $PPM"
fi
