#!/usr/bin/env bash
# Render one block of design/hud-design-system.html to a PNG, the way a
# reviewer would see it: the block's segment activated, the page scrolled so
# the block's <h3> sits at the top. A design promotion is a grep AND a render
# (review 2026-09-03, PR #313: grep passed while a card's label still wrapped).
#
#   scripts/design/render-block.sh "Speech model repair" out.png [height]
#
# The first argument is a substring of the block's <h3> text. Needs Google
# Chrome; writes nothing into the repo.
set -euo pipefail

heading=${1:?heading substring}
out=${2:?output png}
height=${3:-1500}
here=$(cd "$(dirname "$0")/../.." && pwd)
src="$here/design/hud-design-system.html"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$chrome" ] || { echo "Google Chrome not found at $chrome" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
page="$tmp/page.html"
needle=$(printf '%s' "$heading" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
# showSeg() is the page's own segment switcher; the body margin trick puts the
# heading at y=10 without depending on where the page scrolls.
script="<script>window.addEventListener('load',()=>{setTimeout(()=>{const el=[...document.querySelectorAll('h3')].find(e=>e.textContent.includes($needle));if(!el){document.title='NOTFOUND';return;}const seg=el.closest('.segment');if(seg)showSeg(seg.id.replace('seg-',''),false);const top=el.getBoundingClientRect().top+window.scrollY;document.body.style.marginTop=(-top+10)+'px';document.title='FOUND';},300);});</script>"
python3 - "$src" "$page" "$script" <<'EOF'
import sys, pathlib
src, page, script = sys.argv[1:]
html = pathlib.Path(src).read_text()
assert "</body>" in html
pathlib.Path(page).write_text(html.replace("</body>", script + "</body>", 1))
EOF

title=$("$chrome" --headless=new --disable-gpu --virtual-time-budget=6000 --dump-dom "file://$page" 2>/dev/null | grep -o '<title>[^<]*' || true)
[ "$title" = "<title>FOUND" ] || { echo "no <h3> containing: $heading" >&2; exit 1; }
"$chrome" --headless=new --disable-gpu --hide-scrollbars --virtual-time-budget=6000 \
  --window-size="1400,$height" --screenshot="$out" "file://$page" 2>/dev/null
echo "$out"
