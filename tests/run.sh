#!/usr/bin/env bash
# Runs the status line against the sample payloads and a throwaway git repo,
# then checks the plain-text output (ANSI stripped) for the expected segments.
set -u
cd "$(dirname "$0")/.." || exit 1
pass=0; fail=0

# Render a payload and strip color codes and OSC 8 link wrappers for assertions.
# Renders use a fake `claude` launcher so the version check does not depend on this machine.
fake=$(mktemp -d)
mkdir -p "$fake/bin" "$fake/versions"
# The symlink target must exist and be executable, or `command -v` skips it and
# falls through to the real launcher on PATH.
set_launcher() {
  touch "$fake/versions/$1"; chmod +x "$fake/versions/$1"
  rm -f "$fake/bin/claude"; ln -s "$fake/versions/$1" "$fake/bin/claude"
}
set_launcher 2.1.90

render() {
  HOME=/home/user PATH="$fake/bin:$PATH" bash ./statusline.sh < "$1" \
    | sed -e $'s/\033\\]8;;[^\033]*\033\\\\//g' -e $'s/\033\\[[0-9;]*m//g'
}

# expect <label> <haystack> <needle>
expect() {
  if [[ "$2" == *"$3"* ]]; then pass=$((pass + 1))
  else fail=$((fail + 1)); printf 'FAIL %s: expected %q in:\n%s\n' "$1" "$3" "$2"; fi
}
# reject <label> <haystack> <needle>
reject() {
  if [[ "$2" != *"$3"* ]]; then pass=$((pass + 1))
  else fail=$((fail + 1)); printf 'FAIL %s: did not expect %q in:\n%s\n' "$1" "$3" "$2"; fi
}

# ── Full payload: every optional segment present ─────────────────────────────
out=$(render samples/full.json)
expect full-model     "$out" "Opus (high, fast, no-think)"
expect full-dir       "$out" "~/projects/example-app"
expect full-pr        "$out" "#42 changes requested"
expect full-worktree  "$out" "wt: my-feature"
expect full-session   "$out" "refactor auth"
expect full-agent     "$out" "agent: reviewer"
expect full-bar       "$out" "██████░░░░░░░░░░░░░░ 31%"
expect full-tokens    "$out" "62k/200k in · 4k out"
expect full-cost      "$out" '$1.84'
expect full-duration  "$out" "1h12m"
expect full-lines     "$out" "+156 -23"
expect full-limits    "$out" "5h 24% · 7d 81%"
expect full-cache     "$out" "cache cold"
expect full-version   "$out" "· v2.1.90 │"
reject full-restart   "$out" "restart"
expect full-two-lines "$(printf '%s' "$out" | wc -l | tr -d ' ')" "1"
l1=$(printf '%s\n' "$out" | sed -n 1p); l2=$(printf '%s\n' "$out" | sed -n 2p)
expect l1-model    "$l1" "Opus (high"
expect l1-version  "$l1" "v2.1.90 │"
expect l1-dir      "$l1" "~/projects/example-app"
expect l1-pr       "$l1" "#42 changes requested"
expect l1-worktree "$l1" "wt: my-feature"
expect l1-session  "$l1" "refactor auth"
expect l1-agent    "$l1" "agent: reviewer"
reject l1-cost     "$l1" '$1.84'
expect l2-bar      "$l2" "██████░░░░░░░░░░░░░░ 31%"
expect l2-cost     "$l2" '$1.84'
expect l2-cache    "$l2" "cache cold"
reject l2-dir      "$l2" "example-app"


# ── Minimal payload: first render of a session, before any API call ──────────
out=$(render samples/minimal.json)
expect min-model   "$out" "Sonnet"
reject min-effort  "$out" "("
expect min-bar     "$out" "░░░░░░░░░░░░░░░░░░░░ --%"
expect min-tokens  "$out" "0/200k in · 0 out"
expect min-cost    "$out" '$0.00'
expect min-dur     "$out" "0m"
reject min-limits  "$out" "5h"
reject min-cache   "$out" "cache"
reject min-pr      "$out" "#"

# ── Git segment: throwaway repo with one staged, one modified, one untracked ─
tmp=$(mktemp -d)
git -C "$tmp" init -q -b main
git -C "$tmp" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
echo b > "$tmp/tracked.txt";  git -C "$tmp" add tracked.txt
git -C "$tmp" -c user.name=t -c user.email=t@example.com commit -q -m tracked
echo a > "$tmp/staged.txt";   git -C "$tmp" add staged.txt
echo c >> "$tmp/tracked.txt"
echo d > "$tmp/untracked.txt"
mkdir -p "$tmp/src/deep"
echo e > "$tmp/src/one.txt"; echo f > "$tmp/src/two.txt"   # untracked dir: count files, not the dir
payload=$(mktemp)
jq --arg d "$tmp/src/deep" '.workspace.current_dir = $d | .cwd = $d' samples/minimal.json > "$payload"
out=$(render "$payload")
expect git-repo-and-rel "$out" "${tmp##*/}/src/deep"
expect git-branch       "$out" " [main"
expect git-markers      "$out" " [main +1 ~1 ?3]"
reject git-clean-check  "$out" "✓"

# Clean checkout shows the check mark instead of counts.
git -C "$tmp" add -A
git -C "$tmp" -c user.name=t -c user.email=t@example.com commit -q -m all
out=$(render "$payload")
expect git-clean "$out" " [main ✓]"

# Control characters in a session name or a directory name must not reach the output.
evil=$'evil\033]0;pwned\a'
mkdir -p "$tmp/$evil"
payload2=$(mktemp)
jq --arg d "$tmp/$evil" --arg s "$evil" '.workspace.current_dir = $d | .cwd = $d | .session_name = $s' samples/minimal.json > "$payload2"
out=$(bash ./statusline.sh < "$payload2")
reject sanitized-osc "$out" $'\033]0;'
expect sanitized-kept "$out" "evil]0;pwned"
rm -f "$payload2"

# ── Version: launcher newer than the running session → restart notice ───────
set_launcher 2.1.105
out=$(render samples/minimal.json)
expect ver-restart "$out" "v2.1.90 ↑ v2.1.105 restart"
set_launcher 2.1.9                      # older on disk than running: no notice
out=$(render samples/minimal.json)
reject ver-older "$out" "restart"
expect ver-plain "$out" "· v2.1.90 │"
mkdir -p "$fake/versions/Cellar/claude-code/bin"; touch "$fake/versions/Cellar/claude-code/bin/claude"; chmod +x "$fake/versions/Cellar/claude-code/bin/claude"
rm -f "$fake/bin/claude"; ln -s "$fake/versions/Cellar/claude-code/bin/claude" "$fake/bin/claude"   # non-native launcher
out=$(render samples/minimal.json)
reject ver-nonnative "$out" "restart"
set_launcher 2.1.90

# ── Output tokens: deduplicated session total across main + subagent transcripts
tr=$(mktemp -d)
cat > "$tr/session.jsonl" <<'JSONL'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"id":"msg_a","usage":{"output_tokens":100}}}
{"type":"assistant","message":{"id":"msg_a","usage":{"output_tokens":100}}}
{"type":"assistant","message":{"id":"msg_a","usage":{"output_tokens":100}}}
{"type":"assistant","message":{"id":"msg_b","usage":{"output_tokens":50}}}
{"type":"assistant","message":{"id":"msg_b","usage":{"output_tokens":250}}}
{"type":"system","subtype":"noise"}
JSONL
mkdir -p "$tr/session/subagents"
printf '%s\n' '{"type":"assistant","message":{"id":"msg_sub","usage":{"output_tokens":1700}}}' > "$tr/session/subagents/agent-1.jsonl"
payload3=$(mktemp)
jq --arg p "$tr/session.jsonl" '.transcript_path = $p | .context_window.total_output_tokens = 7' samples/minimal.json > "$payload3"
out=$(render "$payload3")
expect out-dedup-sum "$out" "2k out"          # 100 + 250 + 1700 = 2050, not the naive 2300
jq --arg p "$tr/missing.jsonl" '.transcript_path = $p | .context_window.total_output_tokens = 7' samples/minimal.json > "$payload3"
out=$(render "$payload3")
expect out-fallback "$out" "7 out"            # no transcript: payload's last-response figure
jq '.context_window.context_window_size = 1000000 | .context_window.total_input_tokens = 1250000' samples/minimal.json > "$payload3"
out=$(render "$payload3")
expect fmt-million "$out" "1.2M/1M in"        # round millions drop the .0
rm -rf "$tr" "$payload3"

rm -rf "$tmp" "$payload" "$fake"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
