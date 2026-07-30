#!/usr/bin/env bash
# vcs-no-squash-gate.sh — PreToolUse(Bash) VCS command-safety gate.
#
# One process + one jq parse per Bash call runs TWO cheap, text-based checks that
# each carry their OWN deliberate override (so overriding one never disables the
# other):
#
#   A. NO SQUASH / NO REWRITE OF SHARED HISTORY (CLAUDE.md) — override
#      FOUNDLINGS_ALLOW_HISTORY_REWRITE=1. Blocks:
#        1. `jj squash`                      — squashes changes together.
#        2. squash-merge of a PR             — `gh pr merge --squash`/`-s` or a
#                                              `merge_method=squash` API merge.
#        3. `jj rebase -b`/`--branch`        — rebases the entire branch/stack.
#        4. a history-rewriting jj op (`describe`/`squash`/`abandon`/`edit`/
#           `metaedit`) targeting a revision that CURRENTLY HAS a bookmark.
#
#   B. NO `jj new` STRANDING OF A DIRTY @ (CLAUDE.md / kg memory) — override
#      FOUNDLINGS_ALLOW_JJ_NEW_STRANDING=1. `jj new <target>` (a positional
#      target other than @, or -A/-B) starts a NEW empty commit off <target> and
#      moves @ onto it; if the current @ had uncommitted edits they DON'T travel
#      — they stay behind as a sibling and @ becomes an empty commit. Nothing
#      errors, so the mistake is silent (bit us on KG-F, auth/pat, plan-252/008).
#      The safe child-of-@ form (`jj new` / `jj new @`) is never blocked, nor is
#      an already-empty @. Right fix when @ is dirty: `jj rebase -r @ -d <target>`.
#
# PORTABILITY: works on GNU (Linux) and BSD (macOS). grep's `\b` is fine on both;
# BSD sed has NO `\b`, so any sed token-strip below matches a literal prefix only.
set -uo pipefail
input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || printf '')"
[ -n "$cmd" ] || exit 0

# Lazily cd into the workspace the command actually runs in (a leading `cd …` in
# the command wins over the tool cwd). Used only by checks that must query jj.
resolve_ws() {
  local base cdpath start
  base="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || printf '')"
  base="${base:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
  cdpath="$(printf '%s' "$cmd" | grep -oE '(^|[;&|][[:space:]]*)cd[[:space:]]+[^ &;|]+' | head -1 | sed -E 's/.*cd[[:space:]]+//')"
  case "$cdpath" in
    "")  start="$base" ;;
    /*)  start="$cdpath" ;;
    *)   start="$base/$cdpath" ;;
  esac
  cd "$start" 2>/dev/null || cd "$base" 2>/dev/null || return 1
  export PATH="$HOME/.cargo/bin:$PATH"
}

# ============================================================================
# A. no-squash / no-rewrite-shared-history
# ============================================================================
if ! printf '%s' "$cmd" | grep -Eq 'FOUNDLINGS_ALLOW_HISTORY_REWRITE=1'; then
  block_a() {
    echo "VCS GATE BLOCKED: $1" >&2
    echo "Repo rule (CLAUDE.md): we keep commits separate — no squashing, no rewriting shared history." >&2
    echo "If the user EXPLICITLY asked for this, re-run prefixed with FOUNDLINGS_ALLOW_HISTORY_REWRITE=1" >&2
    exit 2
  }

  # 1. jj squash.
  printf '%s' "$cmd" | grep -Eq 'jj +squash\b' \
    && block_a "\`jj squash\` squashes changes together."

  # 2. squash-merge (CLI flag or API merge_method).
  printf '%s' "$cmd" | grep -Eq 'gh +pr +merge\b[^|;&]*(--squash\b|-s\b)' \
    && block_a "\`gh pr merge --squash\` squash-merges the PR (use --merge / merge_method=merge)."
  printf '%s' "$cmd" | grep -Eq 'merge_method=squash' \
    && block_a "a squash merge (merge_method=squash) — use merge_method=merge so commits + change-ids survive."

  # 3. whole-branch / whole-stack rebase.
  printf '%s' "$cmd" | grep -Eq 'jj +rebase\b[^|;&]*(-b\b|--branch\b)' \
    && block_a "\`jj rebase -b/--branch\` rebases the entire branch/stack — rebase a specific revision (-r) instead, or ask first."

  # 4. history-rewriting op on an already-bookmarked revision.
  if printf '%s' "$cmd" | grep -Eq 'jj +(describe|squash|abandon|edit|metaedit)\b'; then
    rev="$(printf '%s' "$cmd" | grep -oE '(-r|--revisions)[ =]+[^ &;|]+' | head -1 | sed -E 's/(-r|--revisions)[ =]+//')"
    rev="${rev:-@}"
    if resolve_ws; then
      bm="$(jj log --no-graph -r "$rev" -T 'bookmarks' 2>/dev/null | tr -d '[:space:]' || printf '')"
      [ -n "$bm" ] \
        && block_a "a history-rewriting jj op targets revision '$rev', which is already bookmarked ($bm)."
    fi
  fi
fi

# ============================================================================
# B. no `jj new` stranding of a dirty @
# ============================================================================
if printf '%s' "$cmd" | grep -Eq 'jj +new\b' \
   && ! printf '%s' "$cmd" | grep -Eq 'FOUNDLINGS_ALLOW_JJ_NEW_STRANDING=1'; then
  # Isolate the `jj new … ` segment (up to the next shell separator) so flags
  # from a later chained command don't confuse target detection.
  seg="$(printf '%s' "$cmd" | grep -oE 'jj +new\b[^;&|]*' | head -1)"
  args="$(printf '%s' "$seg" | sed -E 's/^jj +new//')"                                    # strip literal prefix (BSD sed: no \b)
  args="$(printf '%s' "$args" | sed -E 's/(-m|--message)([= ]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^ ]+))?//g')"  # drop -m/--message + value
  args="$(printf '%s' "$args" | sed -E 's/--no-edit//g; s/(^| )-N( |$)/ /g')"             # drop value-less flags
  # Drop shell REDIRECTIONS before the positional scan. `jj new 2>&1 | tail` is
  # a bare child-of-@ and strands nothing, but the segment grab above cuts at
  # `&`, leaving the fragment `2>` — which is not a flag and not `@`, so it was
  # mistaken for a revset target and blocked a safe command. Order matters:
  # fd-duplication (`2>&1`, `>&2`) first, then file redirects, else the leading
  # fd digit survives as its own bogus positional.
  args="$(printf '%s' "$args" | sed -E 's/[0-9]*>>?&[0-9]*-?//g')"                        # 2>&1, >&2, 2>&-
  args="$(printf '%s' "$args" | sed -E 's/[0-9]*>>?[[:space:]]*[^[:space:]]*//g')"        # 2>/dev/null, > out, trailing `2>`
  args="$(printf '%s' "$args" | sed -E 's/<[[:space:]]*[^[:space:]]*//g')"                # < in

  # A re-parenting target is present if an insert-relative flag is used, or a
  # bare positional revset other than @ remains.
  has_target=0
  printf '%s' "$args" | grep -Eq '(-A|-B|--after|--before|--insert-after|--insert-before)\b' && has_target=1
  if [ "$has_target" -eq 0 ]; then
    for tok in $args; do
      case "$tok" in
        -*|@|"") : ;;        # a flag, child-of-@, or empty — safe
        *)  has_target=1 ;;
      esac
    done
  fi

  if [ "$has_target" -eq 1 ] && resolve_ws; then
    # jj prints `true`/`false`; only block a genuinely non-empty working copy.
    empty="$(jj log --no-graph -r @ -T 'empty' 2>/dev/null | tr -d '[:space:]' || printf '')"
    if [ "$empty" = "false" ]; then
      echo "VCS GATE BLOCKED: \`jj new\` with a re-parenting target while @ has uncommitted edits." >&2
      echo "Those working-copy edits will NOT travel to the new commit — they stay behind in the" >&2
      echo "current change as a sibling, and @ becomes an EMPTY commit off your target." >&2
      echo "" >&2
      echo "If you want the current edits ON that target, move the CHANGE instead:" >&2
      echo "    jj rebase -r @ -d <target>" >&2
      echo "To keep building the current change, just keep editing (or \`jj describe\`/\`jj commit\`)." >&2
      echo "If you REALLY mean to leave the WIP behind and start fresh, re-run prefixed with" >&2
      echo "    FOUNDLINGS_ALLOW_JJ_NEW_STRANDING=1" >&2
      exit 2
    fi
  fi
fi
exit 0
