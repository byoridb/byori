#!/bin/sh
# bulk-read-guard — PreToolUse hook that keeps whole large files out of the
# main model's context.
#
# Reading a large file with Read, or `cat`ing it, spends the most expensive
# tokens in the session on I/O. This guard denies those two shapes and names
# the alternatives: delegate to the byori-bulk-reader agent for a digest, or
# read the exact section with a ranged Read. Ranged reads always pass — they
# are how the delegate itself reads, and how editing work follows a digest's
# line ranges — so the guard needs no exemption list to avoid blocking its
# own delegate.
#
# Installed by install.sh --with-bulk-read-hook. Everything here fails OPEN:
# a guard that cannot decide must not break every Read in the session.

set -u

command -v jq >/dev/null 2>&1 || exit 0

threshold="${BYORI_BULK_READ_MIN_BYTES:-32768}"   # 32 KB — the skill's number
case "$threshold" in ''|*[!0-9]*) threshold=32768 ;; esac

input="$(cat)" || exit 0

deny() { # <path> <bytes>
  jq -cn --arg path "$1" --arg bytes "$2" --arg threshold "$threshold" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("\($path) is \($bytes) bytes (over the \($threshold)-byte bulk-read threshold). Delegate to the byori-bulk-reader agent for a cached digest, or Read the exact section you need with offset/limit.")
    }
  }'
  exit 0
}

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')" || exit 0

file_size() {
  wc -c < "$1" 2>/dev/null | tr -d '[:space:]'
}

if [ "$tool" = "Read" ]; then
  # offset or limit means a ranged read: the caller is taking a section, not
  # the file. That is the sanctioned path for both the delegate and editing.
  ranged="$(printf '%s' "$input" | jq -r \
    'if (.tool_input.offset != null) or (.tool_input.limit != null) then "y" else "n" end')"
  if [ "$ranged" = "y" ]; then exit 0; fi
  path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')"
  if [ -z "$path" ] || [ ! -f "$path" ]; then exit 0; fi
  size="$(file_size "$path")"
  case "$size" in ''|*[!0-9]*) exit 0 ;; esac
  if [ "$size" -gt "$threshold" ]; then deny "$path" "$size"; fi
  exit 0
fi

if [ "$tool" = "Bash" ]; then
  command="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
  # Only a plain `cat` of files floods the context with everything in them. A
  # cat feeding a pipeline is bounded by whatever consumes it, and quoting,
  # substitution, or redirection makes the argument list unknowable from out
  # here — all of those pass rather than guess.
  case "$command" in
    *"|"*|*";"*|*"&"*|*">"*|*"<"*|*'$'*|*'`'*|*"'"*|*'"'*) exit 0 ;;
  esac
  set -f  # a literal *.py in the command must not expand against our cwd
  # shellcheck disable=SC2086 -- word splitting is the parse
  set -- $command
  set +f
  if [ "$#" -lt 2 ] || [ "$1" != "cat" ]; then exit 0; fi
  shift
  total=0
  biggest=""
  biggest_size=0
  for token in "$@"; do
    case "$token" in -*) continue ;; esac
    if [ ! -f "$token" ]; then continue; fi
    size="$(file_size "$token")"
    case "$size" in ''|*[!0-9]*) continue ;; esac
    total=$((total + size))
    if [ "$size" -gt "$biggest_size" ]; then
      biggest="$token"
      biggest_size="$size"
    fi
  done
  if [ "$total" -gt "$threshold" ] && [ -n "$biggest" ]; then
    deny "$biggest" "$total"
  fi
  exit 0
fi

exit 0
