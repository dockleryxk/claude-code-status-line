#!/usr/bin/env bash
# Claude Code status line: two lines, truecolor context bar, no emoji.
#
#   Line 1  Identity: model (effort, fast, no-think) · vX.Y.Z (+ restart notice) │ repo/path [branch +staged ~unstaged ?untracked ↑↓] │ #PR state │ wt: name │ session │ agent: name
#   Line 2  Meters:   context bar pct · tokens in/window · session tokens out · $cost · duration · +added -removed · 5h % · 7d % · cache cold
#
# Reads the status line JSON from stdin (see https://code.claude.com/docs/en/statusline).
# Targets bash 3.2 (macOS default) and needs only jq and git.

input=$(cat)

# ── Colors ───────────────────────────────────────────────────────────────────
# ANSI-C quoting makes the escape bytes literal, so the final print can use
# plain %s and no external string is ever interpreted as an escape sequence.
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
MAGENTA=$'\033[35m'
CYAN=$'\033[36m'
ORANGE=$'\033[38;2;255;140;0m'
GREY=$'\033[38;2;60;60;60m'

# Store a truecolor foreground escape in the variable named by $1 (no subshell).
rgb() { printf -v "$1" '\033[38;2;%d;%d;%dm' "$2" "$3" "$4"; }

# Separators: a dim │ between groups, a dim · between items in a group. Every
# glyph in this script is in the basic Unicode blocks all monospace fonts ship,
# so no Powerline or Nerd Font is needed.
SEP1=" ${DIM}│${RESET} "
SEP2=" ${DIM}·${RESET} "

# ── Parse JSON: one jq call, NUL-separated so values may contain newlines ─────
{
  IFS= read -r -d '' model
  IFS= read -r -d '' effort
  IFS= read -r -d '' fast_mode
  IFS= read -r -d '' thinking
  IFS= read -r -d '' cwd
  IFS= read -r -d '' session_name
  IFS= read -r -d '' agent_name
  IFS= read -r -d '' worktree_name
  IFS= read -r -d '' pr_number
  IFS= read -r -d '' pr_url
  IFS= read -r -d '' pr_state
  IFS= read -r -d '' used
  IFS= read -r -d '' tokens_in
  IFS= read -r -d '' window
  IFS= read -r -d '' tokens_out
  IFS= read -r -d '' cost
  IFS= read -r -d '' duration_ms
  IFS= read -r -d '' lines_add
  IFS= read -r -d '' lines_del
  IFS= read -r -d '' limit_5h
  IFS= read -r -d '' limit_7d
  IFS= read -r -d '' cache_warm
  IFS= read -r -d '' version
  IFS= read -r -d '' transcript
} < <(printf '%s' "$input" | jq -j '[
  .model.display_name // "Claude",
  .effort.level // "",
  .fast_mode // false,
  (.thinking.enabled | if . == null then true else . end),
  .workspace.current_dir // .cwd // "",
  .session_name // "",
  .agent.name // "",
  .worktree.name // "",
  .pr.number // "",
  .pr.url // "",
  .pr.review_state // "",
  .context_window.used_percentage // "",
  .context_window.total_input_tokens // 0,
  .context_window.context_window_size // 0,
  .context_window.total_output_tokens // 0,
  .cost.total_cost_usd // 0,
  .cost.total_duration_ms // 0,
  .cost.total_lines_added // 0,
  .cost.total_lines_removed // 0,
  .rate_limits.five_hour.used_percentage // "",
  .rate_limits.seven_day.used_percentage // "",
  (.prompt_cache.warm | if . == null then "" else . end),
  .version // "",
  .transcript_path // ""
] | map(tostring) | join("\u0000") + "\u0000"')

# ── Sanitize external strings: strip control characters in place ─────────────
# Names from git, the session, the agent and the PR URL are untrusted. Removing
# control bytes stops a crafted name from smuggling in terminal escapes.
sanitize() { printf -v "$1" '%s' "${!1//[[:cntrl:]]/}"; }
sanitize model
sanitize session_name
sanitize agent_name
sanitize worktree_name
sanitize pr_url
sanitize pr_state
sanitize version

# Color for a 0-100 percentage: green, yellow, orange, red as it climbs.
threshold_color() {
  if   [ "$1" -ge 90 ]; then printf -v "$2" '%s' "$RED"
  elif [ "$1" -ge 75 ]; then printf -v "$2" '%s' "$ORANGE"
  elif [ "$1" -ge 50 ]; then printf -v "$2" '%s' "$YELLOW"
  else                       printf -v "$2" '%s' "$GREEN"; fi
}

# ── Model + effort ───────────────────────────────────────────────────────────
model_part="${BOLD}${MAGENTA}${model}${RESET}"
if [ -n "$effort" ]; then
  case "$effort" in
    low)    effort_color="$DIM" ;;
    medium) effort_color="" ;;
    high)   effort_color="$YELLOW" ;;
    xhigh)  effort_color="$ORANGE" ;;
    max)    effort_color="$RED" ;;
    *)      effort_color="" ;;
  esac
fi
# Effort and the fast / no-think flags read as qualifiers of the model, so they
# share one set of parentheses: "Opus (high)", "Opus (high, fast, no-think)".
# The parentheses take the effort's color so "(high)" reads as one unit.
quals=""
[ -n "$effort" ]           && quals="${effort}"
[ "$fast_mode" = "true" ]  && quals="${quals:+${quals}, }${YELLOW}fast${effort_color:-$RESET}"
[ "$thinking" = "false" ]  && quals="${quals:+${quals}, }${DIM}no-think${RESET}${effort_color}"
[ -n "$quals" ]            && model_part="${model_part} ${effort_color}(${quals})${RESET}"

# ── Directory + git ──────────────────────────────────────────────────────────
# One `git status --porcelain=v2 --branch` call yields branch, ahead/behind and
# every file state. -uall counts untracked files rather than collapsing a new
# directory into a single entry, so the number matches what you would commit. Inside a repo the directory shows as repo name plus the
# path below the root; outside a repo it shows home-relative.
dir_part=""
git_part=""
if [ -n "$cwd" ]; then
  # --show-prefix is the path from the repo root to cwd ("" at the root, else "a/b/"),
  # which stays correct when cwd goes through a symlink such as macOS /var → /private/var.
  { IFS= read -r toplevel; IFS= read -r prefix; } < <(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel --show-prefix 2>/dev/null)
  if [ -n "$toplevel" ]; then
    repo=${toplevel##*/}
    rel=${prefix%/}
    sanitize repo
    sanitize rel
    dir_part="${BOLD}${YELLOW}${repo}${RESET}"
    [ -n "$rel" ] && dir_part="${dir_part}${DIM}/${rel}${RESET}"

    branch=""; ahead=0; behind=0; staged=0; unstaged=0; untracked=0
    while IFS= read -r line; do
      case "$line" in
        "# branch.head "*) branch=${line#\# branch.head } ;;
        "# branch.ab "*)
          ab=${line#\# branch.ab }
          ahead=${ab%% *};  ahead=${ahead#+}
          behind=${ab##* }; behind=${behind#-} ;;
        "1 "*|"2 "*)
          # Field 2 is XY: X is the index state, Y the worktree state, '.' means clean.
          xy=${line#? }; xy=${xy%% *}
          [ "${xy:0:1}" != "." ] && staged=$((staged + 1))
          [ "${xy:1:1}" != "." ] && unstaged=$((unstaged + 1)) ;;
        "u "*) unstaged=$((unstaged + 1)) ;;
        "? "*) untracked=$((untracked + 1)) ;;
      esac
    done < <(git -C "$cwd" --no-optional-locks status --porcelain=v2 --branch -uall 2>/dev/null)

    if [ -n "$branch" ]; then
      sanitize branch
      # Space-separated so "~1 ?3" reads as two counts, not one token.
      markers=""
      [ "$staged"    -gt 0 ] && markers="${markers} ${GREEN}+${staged}${RESET}"
      [ "$unstaged"  -gt 0 ] && markers="${markers} ${YELLOW}~${unstaged}${RESET}"
      [ "$untracked" -gt 0 ] && markers="${markers} ${RED}?${untracked}${RESET}"
      [ "$ahead"     -gt 0 ] && markers="${markers} ${GREEN}↑${ahead}${RESET}"
      [ "$behind"    -gt 0 ] && markers="${markers} ${RED}↓${behind}${RESET}"
      [ -z "$markers" ] && markers=" ${GREEN}✓${RESET}"
      # Brackets in the default foreground, same as the token counts on line 2.
      git_part="[${CYAN}${branch}${RESET}${markers}]"
    fi
  else
    shown=$cwd
    [ -n "$HOME" ] && shown=${cwd/#"$HOME"/\~}
    sanitize shown
    dir_part="${BOLD}${YELLOW}${shown}${RESET}"
  fi
fi

# ── Pull request: clickable number (OSC 8), colored by review state ──────────
pr_part=""
if [ -n "$pr_number" ]; then
  case "$pr_state" in
    approved)          pr_color="$GREEN" ;;
    changes_requested) pr_color="$RED" ;;
    draft)             pr_color="$DIM" ;;
    *)                 pr_color="$YELLOW" ;;
  esac
  label="#${pr_number}"
  [ -n "$pr_url" ] && label=$'\033]8;;'"${pr_url}"$'\033\\'"${label}"$'\033]8;;\033\\'
  pr_part="${pr_color}${label}${RESET}"
  [ -n "$pr_state" ] && pr_part="${pr_part} ${DIM}${pr_state//_/ }${RESET}"
fi

# ── Context bar: 20 blocks, RGB gradient green → yellow → red ────────────────
BAR_WIDTH=20
if [ -n "$used" ]; then
  used_int=$(printf '%.0f' "$used")
  filled=$(( (used_int * BAR_WIDTH + 50) / 100 ))
  bar=""
  for (( i=0; i<BAR_WIDTH; i++ )); do
    pos=$(( i * 100 / (BAR_WIDTH - 1) ))
    if [ "$pos" -le 50 ]; then
      r=$(( 220 * pos / 50 )); g=200; b=$(( 80 - 80 * pos / 50 ))
    else
      adj=$(( pos - 50 ))
      r=220; g=$(( 200 - 160 * adj / 50 )); b=$(( 20 * adj / 50 ))
    fi
    if [ "$i" -lt "$filled" ]; then
      rgb color "$r" "$g" "$b"
      bar="${bar}${color}█"
    else
      bar="${bar}${GREY}░"
    fi
  done
  threshold_color "$used_int" pct_color
  ctx_part="${bar}${RESET} ${pct_color}${used_int}%${RESET}"
else
  ctx_part="${GREY}░░░░░░░░░░░░░░░░░░░░${RESET} ${DIM}--%${RESET}"
fi

# ── Session output tokens from the transcript ────────────────────────────────
# The payload's total_output_tokens is the last response only. The transcript
# has every response, so sum it. Each assistant message is written as several
# entries (one per content block) that repeat the same usage, so take one value
# per message id. Subagent transcripts sit in <session>/subagents/ and count too,
# matching what total_cost_usd already includes. Skipped past 50MB to keep the
# render fast; then the last-response figure from the payload is shown instead.
if [ -n "$transcript" ] && [ -r "$transcript" ]; then
  files=("$transcript")
  for f in "${transcript%.jsonl}"/subagents/*.jsonl; do [ -r "$f" ] && files+=("$f"); done
  size=$(wc -c < "$transcript")
  if [ "${size:-0}" -le 52428800 ]; then
    total=$(jq -n 'reduce inputs as $e ({};
        if $e.type == "assistant" and ($e.message.id | type) == "string"
        then .[$e.message.id] = ([.[$e.message.id] // 0, ($e.message.usage.output_tokens // 0)] | max)
        else . end) | add // 0' "${files[@]}" 2>/dev/null)
    case "$total" in ''|*[!0-9]*) ;; *) tokens_out=$total ;; esac
  fi
fi

# ── Tokens: 850 → "850", 62400 → "62k", 1250000 → "1.2M" ─────────────────────
# Input is everything currently in the context window. Output is the session
# total from the transcript when available, else the last response.
fmt_tokens() {
  local n=${2%%.*}
  if   [ "$n" -ge 1000000 ]; then
    tenths=$(( n % 1000000 / 100000 ))   # one decimal, dropped when it is zero: 1M, 1.2M
    if [ "$tenths" -eq 0 ]; then printf -v "$1" '%dM' $(( n / 1000000 ))
    else                         printf -v "$1" '%d.%dM' $(( n / 1000000 )) "$tenths"; fi
  elif [ "$n" -ge 1000 ];    then printf -v "$1" '%dk' $(( n / 1000 ))
  else                            printf -v "$1" '%d' "$n"; fi
}
fmt_tokens tokens_in_fmt "$tokens_in"
fmt_tokens tokens_out_fmt "$tokens_out"
# Window size after the input count, so the percentage is self-explanatory:
# 141k reads very differently on a 200k window than on a 1M one.
tokens_part="${tokens_in_fmt}"
[ "${window%%.*}" -gt 0 ] 2>/dev/null && { fmt_tokens window_fmt "$window"; tokens_part="${tokens_part}${DIM}/${window_fmt}${RESET}"; }
tokens_part="${tokens_part} ${DIM}in${RESET}${SEP2}${tokens_out_fmt} ${DIM}out${RESET}"

# ── Cost, duration, lines changed ────────────────────────────────────────────
cost_part="${YELLOW}$(printf '$%.2f' "$cost")${RESET}"

mins=$(( ${duration_ms%%.*} / 60000 ))
if [ "$mins" -ge 60 ]; then duration_part="$(( mins / 60 ))h$(( mins % 60 ))m"
else                        duration_part="${mins}m"; fi
duration_part="${DIM}${duration_part}${RESET}"

lines_part="${GREEN}+${lines_add}${RESET} ${RED}-${lines_del}${RESET}"

# ── Rate limits (Pro/Max only; absent otherwise) ─────────────────────────────
limits_part=""
if [ -n "$limit_5h" ]; then
  v=$(printf '%.0f' "$limit_5h"); threshold_color "$v" c
  limits_part="${DIM}5h${RESET} ${c}${v}%${RESET}"
fi
if [ -n "$limit_7d" ]; then
  v=$(printf '%.0f' "$limit_7d"); threshold_color "$v" c
  limits_part="${limits_part:+${limits_part}${SEP2}}${DIM}7d${RESET} ${c}${v}%${RESET}"
fi

# ── Prompt cache: say something only when it has gone cold ───────────────────
cache_part=""
[ "$cache_warm" = "false" ] && cache_part="${BLUE}cache cold${RESET}"

# ── Version + pending update ─────────────────────────────────────────────────
# The native installer downloads new versions in the background and repoints
# the `claude` launcher symlink, but a running session stays on the old binary.
# If the launcher resolves to a newer version than this session reports, say so.
# Zero network: one `readlink`. Non-native installs (brew, npm) resolve to a
# path that is not a version number, so they just show the running version.
version_part=""
if [ -n "$version" ]; then
  version_part="${DIM}v${version}${RESET}"
  launcher=$(command -v claude 2>/dev/null)
  [ -z "$launcher" ] && [ -x "$HOME/.local/bin/claude" ] && launcher="$HOME/.local/bin/claude"
  installed=""
  if [ -n "$launcher" ]; then
    target=$(readlink "$launcher" 2>/dev/null)
    case "$target" in
      /*) ;;                                  # absolute symlink target
      ?*) target="${launcher%/*}/$target" ;;  # relative target: resolve beside the launcher
    esac
    installed=${target##*/}
    case "$installed" in
      [0-9]*.[0-9]*.[0-9]*) ;;
      *) installed="" ;;
    esac
  fi
  if [ -n "$installed" ] && [ "$installed" != "$version" ]; then
    # Numeric compare of major.minor.patch; only flag when installed is newer.
    IFS=. read -r r1 r2 r3 <<< "$version"
    IFS=. read -r i1 i2 i3 <<< "$installed"
    newer=0
    if   [ "${i1:-0}" -gt "${r1:-0}" ]; then newer=1
    elif [ "${i1:-0}" -eq "${r1:-0}" ] && [ "${i2:-0}" -gt "${r2:-0}" ]; then newer=1
    elif [ "${i1:-0}" -eq "${r1:-0}" ] && [ "${i2:-0}" -eq "${r2:-0}" ] && [ "${i3:-0}" -gt "${r3:-0}" ]; then newer=1; fi
    [ "$newer" -eq 1 ] && version_part="${YELLOW}v${version} ↑ v${installed} restart${RESET}"
  fi
fi

# ── Assemble ─────────────────────────────────────────────────────────────────
# Line 1 is identity (what is running, where). Line 2 is every number that
# moves each turn, so the eye lands in the same place every time.
line1="$model_part"
[ -n "$version_part" ] && line1="${line1}${SEP2}${version_part}"
if [ -n "$dir_part" ]; then
  line1="${line1}${SEP1}${dir_part}"
  [ -n "$git_part" ] && line1="${line1} ${git_part}"
fi
[ -n "$pr_part" ]       && line1="${line1}${SEP1}${pr_part}"
[ -n "$worktree_name" ] && line1="${line1}${SEP1}${DIM}wt:${RESET} ${worktree_name}"
[ -n "$session_name" ]  && line1="${line1}${SEP1}${DIM}${session_name}${RESET}"
[ -n "$agent_name" ]    && line1="${line1}${SEP1}${DIM}agent:${RESET} ${agent_name}"

line2="${ctx_part}${SEP2}${tokens_part}${SEP2}${cost_part}${SEP2}${duration_part}${SEP2}${lines_part}"
[ -n "$limits_part" ] && line2="${line2}${SEP2}${limits_part}"
[ -n "$cache_part" ]  && line2="${line2}${SEP2}${cache_part}"

printf '%s\n%s\n' "$line1" "$line2"
