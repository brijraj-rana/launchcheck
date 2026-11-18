#!/bin/bash
# Rebuilds site/index.html from site/index.template.html, with the app's own check catalogue written into it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product launchcheck-cli >/dev/null
"$(swift build --show-bin-path)/launchcheck-cli" --checks > site/assets/checks.json
python3 - <<'PY'
import json
checks = json.load(open("site/assets/checks.json"))
slim = [{k: c[k] for k in ("severity", "area", "title", "why")} for c in checks]
data = json.dumps(slim, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
page = open("site/index.template.html").read().replace("__CHECKS__", data)
open("site/index.html", "w").write(page)
print(f"Wrote site/index.html with {len(slim)} checks")
PY
