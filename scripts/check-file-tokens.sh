#!/bin/sh
# Refuse to commit a hand-written source file above the token budget
# (tokens ≈ bytes / 4).
#
# This is the repo's own copy of the rule, so the limit is version-controlled
# instead of living in one machine's global hook. Reads the staged file list on
# stdin, so it runs standalone:
#
#   git diff --cached --name-only --diff-filter=ACM | scripts/check-file-tokens.sh
#
# Configuration, lowest priority first:
#   1. the default below;
#   2. `.git-hooks.conf` at the repo root (GIT_HOOK_MAX_TOKENS, GIT_HOOK_EXEMPT);
#   3. environment variables of the same names.
#
# Generated code, vendor trees, lockfiles and archives are always exempt.
# There is no grandfather clause: an existing file over the limit must be split,
# or moved into an archive directory that the exemption names.
set -eu
# `GIT_HOOK_EXEMPT` holds glob patterns; stop the shell from expanding them
# against the working tree before `case` sees them.
set -f

max_tokens=5500

conf_get() {
	[ -f .git-hooks.conf ] || return 0
	sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" .git-hooks.conf |
		tail -1 | sed 's/[[:space:]]*$//; s/^"//; s/"$//'
}

DEFAULT_EXEMPT="legacy/* */legacy/* docs/archive/* archive/* archived/* */archive/* */archived/*"
exempt="$DEFAULT_EXEMPT"

v=$(conf_get GIT_HOOK_MAX_TOKENS)
if [ -n "$v" ]; then max_tokens=$v; fi
v=$(conf_get GIT_HOOK_EXEMPT)
if [ -n "$v" ]; then exempt="$DEFAULT_EXEMPT $v"; fi

if [ -n "${GIT_HOOK_MAX_TOKENS:-}" ]; then max_tokens=$GIT_HOOK_MAX_TOKENS; fi
if [ -n "${GIT_HOOK_EXEMPT:-}" ]; then exempt="$DEFAULT_EXEMPT $GIT_HOOK_EXEMPT"; fi

staged=$(cat)
[ "$max_tokens" -gt 0 ] || exit 0

is_exempt() {
	for pat in $exempt; do
		case "$1" in $pat) return 0 ;; esac
	done
	return 1
}

over=""
for f in $staged; do
	[ -f "$f" ] || continue
	case "$f" in
	*.rs | *.swift | *.sh) ;;
	*) continue ;;
	esac
	case "$f" in
	*.lock | *-lock.json | *.min.js | *.min.css | *.gen.* | *_generated.* | */vendor/* | */generated/* | */gen/*) continue ;;
	esac
	if is_exempt "$f"; then continue; fi

	sz=$(wc -c <"$f" | tr -d ' ')
	tk=$((sz / 4))
	if [ "$tk" -gt "$max_tokens" ]; then
		over="$over$f (~${tk} tokens)
"
	fi
done

if [ -n "$over" ]; then
	printf 'pre-commit: these files exceed the %s token budget (tokens ≈ bytes/4):\n%s' \
		"$max_tokens" "$over" >&2
	printf 'Split them by responsibility. Archive directories are exempt.\n' >&2
	exit 1
fi

exit 0
