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
[ -f site/assets/portavoz-icon.svg ] || fail "site/assets/portavoz-icon.svg is missing"
[ -f site/assets/og.png ] || fail "site/assets/og.png is missing (social/OG card)"
for screenshot in today meeting-detail recording-live-translation insights; do
	[ -f "site/assets/screenshots/$screenshot.png" ] \
		|| fail "site screenshot is missing: $screenshot.png"
done

# The site is bilingual (ES default + EN toggle); it declares a lang and the
# data-lang marker that drives the in-page switcher.
grep -qE '<html lang="(es|en)"' site/index.html || fail "site/index.html must declare a lang"
grep -q 'data-lang=' site/index.html || fail "site/index.html must carry the bilingual data-lang marker"
grep -qi '<title>portavoz' site/index.html || fail "site/index.html must set a Portavoz title"
grep -qi 'brew install --cask johnny4young/tap/portavoz' site/index.html \
	|| fail "site/index.html must carry the fully qualified install command"
grep -q 'CHANGELOG.md' site/index.html || fail "site/index.html must link release notes/changelog"

# The site wears the design system's Night values; its :root must not drift.
ds_dark="$(sed -n '/^\[data-theme="dark"\]/,/^}/p' docs/design/ds/tokens/colors.css)"
site_root="$(sed -n '/^:root {/,/^}/p' site/styles.css)"
token_value() { printf '%s\n' "$1" | sed -n "s/^ *--$2: *\(#[0-9a-fA-F]\{6\}\);.*/\1/p" | head -n 1; }
for pair in paper:paper card:card ink:ink ink-3:ink-3 cobalt:voice-1 madder:voice-2; do
	site_name="${pair%%:*}" ds_name="${pair##*:}"
	site_value="$(token_value "$site_root" "$site_name")"
	ds_value="$(token_value "$ds_dark" "$ds_name")"
	[ -n "$site_value" ] && [ "$site_value" = "$ds_value" ] \
		|| fail "site --$site_name ($site_value) must equal the DS dark --$ds_name ($ds_value)"
done
site_amber="$(token_value "$site_root" amber)"
ds_amber="$(token_value "$(sed -n '/^:root {/,/^}/p' docs/design/ds/tokens/colors.css)" you)"
[ -n "$site_amber" ] && [ "$site_amber" = "$ds_amber" ] \
	|| fail "site --amber ($site_amber) must equal the DS --you ($ds_amber)"

# No insecure URLs (SVG/XML namespace identifiers are not fetches).
if grep -RIn --exclude='*.svg' 'http://' site >/dev/null 2>&1; then
	fail "site/ must not use insecure http:// URLs"
fi

printf '✓ site structure OK\n'
