#!/bin/sh
set -eu

remote="${1:-origin}"
target_repo="michaeltorbert/spaces-manager"

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

remote_url="$(git remote get-url "$remote" 2>/dev/null || true)"
case "$remote_url" in
  https://github.com/michaeltorbert/spaces-manager.git|\
  git@github.com:michaeltorbert/spaces-manager.git|\
  ssh://git@github.com/michaeltorbert/spaces-manager.git)
    ;;
  *)
    die "Refusing to continue: $remote remote is '$remote_url', not $target_repo."
    ;;
esac

remote_main_sha="$(git ls-remote --exit-code "$remote" refs/heads/main | awk '{print $1}')"
[ -n "$remote_main_sha" ] ||
  die "Refusing to continue: could not read live $remote/main."

if ! git cat-file -e "$remote_main_sha^{commit}" 2>/dev/null; then
  git fetch --quiet --no-write-fetch-head "$remote" refs/heads/main ||
    die "Refusing to continue: live $remote/main is not present locally and could not be fetched."
fi

branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[ -n "$branch" ] || die "Refusing to continue: detached HEAD. Create a feature branch from $remote/main."
[ "$branch" != "main" ] || die "Refusing to continue: do not commit or push from local main."

if ! git merge-base --is-ancestor "$remote_main_sha" HEAD; then
  behind="$(git rev-list --count "HEAD..$remote_main_sha" 2>/dev/null || printf 'unknown')"
  die "Refusing to continue: $branch does not contain current $remote/main ($behind commits behind). Rebase or merge $remote/main first."
fi

printf 'OK: %s is a feature branch based on current %s/main.\n' "$branch" "$remote"
