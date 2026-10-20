#!/usr/bin/env bash
# Renders the README example as docs/statusline.svg from the real script output.
# Needs freeze (brew install charmbracelet/tap/freeze). Run after any change
# that alters what the status line prints.
set -eu
cd "$(dirname "$0")/.."
command -v freeze >/dev/null || { echo "freeze not found: brew install charmbracelet/tap/freeze" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
g() { git -C "$tmp/example-app" -c user.name=t -c user.email=t@example.com "$@"; }

# Throwaway repo in the state the README shows: [main +2 ~1 ↑1] with cwd in src/.
# Ahead-of-upstream needs a remote, so a bare repo beside it plays origin.
mkdir -p "$tmp/example-app/src"
git init -q --bare "$tmp/origin.git"
g init -q -b main
g remote add origin "$tmp/origin.git"
echo a > "$tmp/example-app/src/app.js"
g add -A && g commit -q -m init && g push -q -u origin main
g commit -q --allow-empty -m "local only"       # ↑1
echo b > "$tmp/example-app/src/new1.js"; echo c > "$tmp/example-app/src/new2.js"
g add src/new1.js src/new2.js                   # +2
echo d >> "$tmp/example-app/src/app.js"         # ~1

# Fake launcher at the same version the payload reports, so the render never
# shows this machine's pending-restart notice.
version=2.1.304
mkdir -p "$tmp/bin" "$tmp/versions"
touch "$tmp/versions/$version"; chmod +x "$tmp/versions/$version"
ln -s "$tmp/versions/$version" "$tmp/bin/claude"

# Payload: samples/full.json trimmed to the segments the README example shows.
jq --arg d "$tmp/example-app/src" --arg v "$version" '
  .workspace.current_dir = $d | .cwd = $d | .version = $v
  | .fast_mode = false | .thinking.enabled = true
  | .pr.review_state = "pending"
  | .rate_limits.five_hour.used_percentage = 23 | .rate_limits.seven_day.used_percentage = 41
  | .prompt_cache.warm = true
  | del(.session_name, .agent, .transcript_path)
' samples/full.json > "$tmp/payload.json"

# Render through freeze on stdin; --execute needs a pty and fails under sandboxes.
# The command substitution drops the trailing newline, which freeze would
# otherwise draw as an empty third line.
out=$(HOME="$tmp" PATH="$tmp/bin:$PATH" bash statusline.sh < "$tmp/payload.json")
# Padding is top,right,bottom,left. Freeze leaves about a line of slack under
# the last row, so zero bottom padding gives visually even margins.
printf '%s' "$out" | freeze --language ansi --padding 24,28,0,28 --output docs/statusline.svg
