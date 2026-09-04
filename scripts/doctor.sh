#!/bin/bash
# Read-only environment check for Undertone. Never installs or changes anything.
set -uo pipefail
MIN_YTDLP="2026.08.19"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }

echo "macOS:  $(sw_vers -productVersion)"
echo "Swift:  $(swift --version 2>&1 | head -1 | sed 's/.*Swift version /Swift /' | cut -d' ' -f1-2)"
echo
echo "yt-dlp"
YTDLP="$(command -v yt-dlp || ls /opt/homebrew/bin/yt-dlp /usr/local/bin/yt-dlp "$HOME/.local/bin/yt-dlp" 2>/dev/null | head -1 || true)"
if [ -z "$YTDLP" ]; then
  bad "not found. Install with: brew install yt-dlp"
else
  V="$("$YTDLP" --version 2>/dev/null | tail -1)"
  if [ "$(printf '%s\n%s\n' "$MIN_YTDLP" "$V" | sort -V | head -1)" = "$MIN_YTDLP" ]; then
    ok "$YTDLP ($V)"
  else
    warn "$YTDLP is $V; YouTube needs >= $MIN_YTDLP. Update with: brew upgrade yt-dlp"
  fi
fi
echo
echo "JavaScript runtime (yt-dlp needs one for YouTube)"
DENO="$(command -v deno || ls /opt/homebrew/bin/deno /usr/local/bin/deno "$HOME/.deno/bin/deno" 2>/dev/null | head -1 || true)"
if [ -n "$DENO" ]; then ok "deno: $DENO ($("$DENO" --version 2>/dev/null | head -1 | cut -d' ' -f2))"; else warn "deno not found (brew install deno); yt-dlp may fall back to node if present"; fi
echo
echo "Build output"
if [ -d build/Undertone.app ]; then ok "build/Undertone.app present ($(defaults read "$PWD/build/Undertone.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null))"; else warn "not built yet: make build"; fi
if [ -d /Applications/Undertone.app ]; then ok "/Applications/Undertone.app installed"; else warn "not installed: make install"; fi
