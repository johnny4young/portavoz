#!/usr/bin/env bash
# Lightweight structural check for the static landing (pattern shared with
# Gancho). Run by the Website workflow before deploying to Cloudflare Pages.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

fail() {
	printf '✗ %s\n' "$1" >&2
	exit 1
}

[ -f site/index.html ] || fail "site/index.html is missing"
[ -f site/styles.css ] || fail "site/styles.css is missing"
[ -f site/assets/portavoz-mark.svg ] || fail "site/assets/portavoz-mark.svg is missing"
[ -f site/assets/og.png ] || fail "site/assets/og.png is missing (social/OG card)"

# The site is bilingual (ES default + EN toggle); it declares a lang and the
# data-lang marker that drives the in-page switcher.
grep -qE '<html lang="(es|en)"' site/index.html || fail "site/index.html must declare a lang"
grep -q 'data-lang=' site/index.html || fail "site/index.html must carry the bilingual data-lang marker"
grep -qi '<title>portavoz' site/index.html || fail "site/index.html must set a Portavoz title"
grep -qi 'brew install --cask portavoz' site/index.html || fail "site/index.html must carry the install command"
grep -q 'CHANGELOG.md' site/index.html || fail "site/index.html must link release notes/changelog"

# No insecure URLs (SVG/XML namespace identifiers are not fetches).
if grep -RIn --exclude='*.svg' 'http://' site >/dev/null 2>&1; then
	fail "site/ must not use insecure http:// URLs"
fi

printf '✓ site structure OK\n'
