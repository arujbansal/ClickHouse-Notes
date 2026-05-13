#!/usr/bin/env bash
#
# Symlink this ClickHouse-Notes checkout into a ClickHouse working copy,
# and tell that working copy's git to ignore the symlink locally.
#
# Usage: ./setup.sh <path-to-clickhouse-repo>

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path-to-clickhouse-repo>" >&2
    exit 2
fi

target_repo=$1

if [ ! -d "$target_repo" ]; then
    echo "error: '$target_repo' is not a directory" >&2
    exit 1
fi

# Resolve to an absolute path so the symlink works regardless of CWD at use time.
target_repo=$(cd "$target_repo" && pwd -P)

if [ ! -d "$target_repo/.git" ] && [ ! -f "$target_repo/.git" ]; then
    echo "error: '$target_repo' is not a git working copy (no .git)" >&2
    exit 1
fi

notes_dir=$(cd "$(dirname "$0")" && pwd -P)
link_name=$(basename "$notes_dir")
link_path="$target_repo/$link_name"

# Create or refresh the symlink.
if [ -L "$link_path" ]; then
    existing=$(readlink "$link_path")
    if [ "$existing" = "$notes_dir" ]; then
        echo "symlink already points to $notes_dir; leaving it"
    else
        echo "error: '$link_path' is a symlink to '$existing', not '$notes_dir'" >&2
        echo "remove it manually if you want to repoint it" >&2
        exit 1
    fi
elif [ -e "$link_path" ]; then
    echo "error: '$link_path' already exists and is not a symlink" >&2
    exit 1
else
    ln -s "$notes_dir" "$link_path"
    echo "created symlink: $link_path -> $notes_dir"
fi

# Resolve the git dir (handles both regular repos and worktrees, where .git is a file).
git_dir=$(git -C "$target_repo" rev-parse --git-dir)
case "$git_dir" in
    /*) ;;
    *) git_dir="$target_repo/$git_dir" ;;
esac

exclude_file="$git_dir/info/exclude"
mkdir -p "$(dirname "$exclude_file")"
touch "$exclude_file"

# Add an entry that ignores the symlink and anything beneath it, if not already present.
# The leading '/' anchors the pattern to the repo root so it doesn't accidentally match
# a nested directory of the same name.
entry="/$link_name"
if grep -Fxq "$entry" "$exclude_file"; then
    echo "git exclude already ignores $entry"
else
    printf '%s\n' "$entry" >> "$exclude_file"
    echo "added '$entry' to $exclude_file"
fi
