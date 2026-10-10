#!/bin/sh
# Prints the git identity of the checkout a build is made from (#473), for the app's Debug-only main-menu footer
# (Regatta/App/BuildIdentity.swift). The Regatta target's "Stamp build identity" phase runs it on every Debug build
# and writes the output into the built app (BuildID.txt), never into the source tree.
#
#   scripts/build-id.sh [<checkout>]      default: the current directory
#
#   commit=1998032                        short hash of HEAD; "unknown" without git or outside a repository
#   dirty=1                               1 when tracked files have uncommitted changes, else 0
#   branch=build/461-default-skiff8       empty when HEAD is detached
#
# Works in a git worktree (git finds the common directory itself). Always exits 0.
dir="${1:-.}"
commit="$(git -C "$dir" rev-parse --short=7 HEAD 2>/dev/null)" || commit=""
if [ -z "$commit" ]; then
    printf 'commit=unknown\ndirty=0\nbranch=\n'
    exit 0
fi
dirty=0
# Untracked files don't count: a checkout keeps local schemes and traces around.
if [ -n "$(git --no-optional-locks -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    dirty=1
fi
branch="$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null)" || branch=""
printf 'commit=%s\ndirty=%s\nbranch=%s\n' "$commit" "$dirty" "$branch"
