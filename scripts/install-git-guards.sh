#!/bin/sh
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"

remote_url="$(git remote get-url origin 2>/dev/null || true)"
case "$remote_url" in
  https://github.com/michaeltorbert/spaces-manager.git|\
  git@github.com:michaeltorbert/spaces-manager.git|\
  ssh://git@github.com:michaeltorbert/spaces-manager.git)
    ;;
  *)
    printf 'Refusing to install hooks: origin is %s, not michaeltorbert/spaces-manager.\n' "$remote_url" >&2
    exit 1
    ;;
esac

set_config() {
  key="$1"
  value="$2"
  git config --local "$key" "$value" || {
    printf 'Could not write local git config (%s=%s). This clone may have read-only or poisoned .git metadata; use a healthy clone or fix .git permissions before agent work.\n' "$key" "$value" >&2
    exit 1
  }
}

set_config core.hooksPath .githooks
set_config pull.ff only
set_config fetch.prune true
set_config push.default simple

git ls-remote --exit-code origin refs/heads/main >/dev/null || {
  printf 'Installed hooks, but could not read origin/main. Verify network/auth before work.\n' >&2
  exit 1
}

printf 'Installed git guards for %s.\n' "$root"
printf 'Configured core.hooksPath=.githooks, pull.ff=only, fetch.prune=true, push.default=simple.\n'
