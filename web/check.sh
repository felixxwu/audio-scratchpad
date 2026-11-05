#!/bin/sh
# Runs the web version's self-check in headless Chrome, which reports its result by requesting a special address.
set -u
cd "$(dirname "$0")"

chrome="${CHROME:-}"
if [ -z "$chrome" ]; then
    if [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
        chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    else
        chrome=google-chrome
    fi
fi

work=$(mktemp -d)
port=8765
python3 -m http.server "$port" --bind 127.0.0.1 >"$work/log" 2>&1 &
server=$!
sleep 1
"$chrome" --headless=new --no-sandbox --no-first-run --autoplay-policy=no-user-gesture-required \
    --user-data-dir="$work/profile" "http://localhost:$port/index.html?selfcheck" >/dev/null 2>&1 &
browser=$!
trap 'kill "$server" "$browser" 2>/dev/null; sleep 1; rm -rf "$work"' EXIT

for _ in $(seq 60); do
    if grep -q "selfcheck-passed" "$work/log"; then
        echo "Self-check passed"
        exit 0
    fi
    if grep -q "selfcheck-failed" "$work/log"; then
        echo "Self-check failed:"
        grep "selfcheck-failed" "$work/log" | sed -E 's/.*selfcheck-failed\/([^ ]*).*/\1/' | python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read()))'
        exit 1
    fi
    sleep 1
done
echo "Self-check timed out"
exit 1
