# Releasing Portavoz

The end-to-end recipe for cutting a public release: a notarized DMG that
updates existing users via **Sparkle** and new users via **Homebrew**. Written
from the real flow (v0.1.0 → v0.6.0, seven releases). Follow it top to bottom.

Distribution is direct-download only (no App Store) — decision D10/D20.

## 0. One-time machine setup (already done on the author's Mac)

These must exist before a release; verify them (§2) rather than re-creating:

| Requirement | What / why |
|---|---|
| **Developer ID Application cert** | in the login keychain, for codesigning |
| **`portavoz-notary` notarytool profile** | `xcrun notarytool store-credentials portavoz-notary` (Apple ID + app-specific password + team id) |
| **`generate_appcast`** at `~/.local/bin/generate_appcast` | from the Sparkle release; signs the appcast with the **`portavoz`** EdDSA key in the keychain (`--account portavoz`) |
| **`gh`** authenticated | `gh auth status` |

## 1. Pre-flight (repo must be clean & green)

```sh
git switch main && git pull --ff-only origin main
git status --short          # must be empty — clean any stray *.d / *.dia / *.swiftdeps first
swift test                  # green (DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test if "no such module")
swiftlint --strict          # 0 violations
```

- **CHANGELOG.md** has every user-visible change since the last release, newest first.
- Decide the **version** (SemVer): patch for fixes, minor for features. Last tag: `git tag --list 'v*' | sort -V | tail -1`.
- Stray SwiftPM artifacts (`*.d`, `*.dia`, `*.swiftdeps`) sometimes leak to the repo root from an Xcode/XCUITest build — they are **not** git-ignored, so delete them before releasing.

## 2. Verify the release prerequisites

```sh
# Signing identity — MUST resolve to the SHA-1 hash, see the gotcha below.
security find-identity -v -p codesigning | grep 8C8B5B1453BB7E3CC48D78FE2D4A47AC6EBB9D17
# Notary profile works:
xcrun notarytool history --keychain-profile portavoz-notary | head -3
# Appcast signer present:
ls -l ~/.local/bin/generate_appcast
```

> **GOTCHA — two duplicate Developer ID identities.** The keychain holds two
> certs both named `Developer ID Application: Johnny IV Young (JGWX5ZT2N2)`, so
> passing the **name** makes `codesign` fail with *"ambiguous"*. Always pass the
> **SHA-1 hash** `8C8B5B1453BB7E3CC48D78FE2D4A47AC6EBB9D17` as
> `PORTAVOZ_SIGN_IDENTITY`.

## 3. Build + notarize (local — nothing is public yet)

```sh
export PORTAVOZ_SIGN_IDENTITY="8C8B5B1453BB7E3CC48D78FE2D4A47AC6EBB9D17"
export PORTAVOZ_NOTARY_PROFILE="portavoz-notary"
scripts/make-release.sh <version>      # e.g. 0.5.1
```

`scripts/make-release.sh` (see its header) does, in order:
1. `make-app.sh --release --version <v> --build <YYYYMMDDHHMM>` — version-stamps + builds + signs the `.app`.
2. `make-dmg.sh --skip-build` — archives and notarizes the signed app, staples
   and verifies it, packages that app into the DMG, then independently
   notarizes/staples the DMG. It mounts the result and verifies a copied-out
   app exactly as Homebrew will consume it.
3. Generates the **EdDSA-signed `appcast.xml`** (`generate_appcast --account portavoz`).
4. Renders the Homebrew **cask** with the real version + sha256.

Output lands in **`dist/release/`**: `Portavoz-<version>.dmg`, `appcast.xml`, `portavoz.rb`.

It takes several minutes (the Swift release build + Apple notarization). Run it
in the background and wait for `Release <version> ready in dist/release/`.

### Verify the artifacts before publishing

```sh
scripts/verify-distribution.sh dist/release/Portavoz-<version>.dmg # DMG + extracted app both accepted/stapled
grep -E 'sparkle:version|edSignature' dist/release/appcast.xml # version + signature present
grep -E 'version |sha256 ' dist/release/portavoz.rb            # match the DMG
```

The distribution verifier is intentionally stricter than opening the DMG. A
stapled outer image can open while a cask-extracted app has no embedded ticket
and must reach Apple's service at first launch. Never publish unless both
boundaries pass.

## 4. Publish (outward-facing — get an explicit OK first)

**The author prefers to review the built DMG + notes and give an explicit "OK"
before this step.** Stop after §3, show the artifacts, then run §4 on approval.

```sh
git push origin main                                   # if main has unpushed commits
git tag v<version> && git push origin v<version>

gh release create v<version> \
  dist/release/Portavoz-<version>.dmg \
  dist/release/appcast.xml \
  --title "Portavoz <version> — <catchy phrase>" \
  --notes-file <release-notes.md>

gh workflow run update-cask.yml -f tag=v<version>      # bumps johnny4young/homebrew-tap
```

- **Attach BOTH** the DMG and `appcast.xml` — Sparkle fetches the appcast from
  `releases/latest/download/appcast.xml`, and the cask/appcast link to
  `releases/download/v<version>/Portavoz-<version>.dmg`.
- **Release notes**: compile from the CHANGELOG entries added since the previous
  tag (`git log v<prev>..HEAD`). A "Highlights" list, then "Also in this
  release", ending with *"runs 100% on your Mac. Update from within Portavoz, or
  `brew upgrade --cask portavoz`."*

### Title format — keep it consistent

`Portavoz <version> — <lowercase, catchy phrase>`. The dash is an em dash (`—`).

| Tag | Title |
|---|---|
| v0.5.1 | Portavoz 0.5.1 — custom structures, and the call on AirPods |
| v0.5.0 | Portavoz 0.5.0 — a new look, and a mirror |
| v0.4.0 | Portavoz 0.4.0 — safety nets and sharper gestures |
| v0.3.0 | Portavoz 0.3.0 — your meetings, portable |
| v0.2.0 | Portavoz 0.2.0 — lives on your Mac, not just in its window |
| v0.1.0 | Portavoz 0.1.0 — knows who said what, locally |

## 5. Verify it's live

```sh
gh release view v<version> --json assets -q '[.assets[].name] | join(", ")'   # appcast.xml, Portavoz-<version>.dmg
gh run watch <cask-run-id> --exit-status                                        # update-cask workflow succeeds
curl -s https://raw.githubusercontent.com/johnny4young/homebrew-tap/main/Casks/portavoz.rb | grep -E 'version |sha256 '
curl -sIL https://github.com/johnny4young/portavoz/releases/download/v<version>/Portavoz-<version>.dmg | grep -i '^HTTP'  # 200
```

Existing users now see Sparkle's "Update available"; Homebrew users can
`brew upgrade --cask portavoz`.

### Reproduce the Homebrew extraction boundary

After the cask workflow is live, install to a disposable app directory instead
of replacing the maintainer's release app:

```sh
APPDIR="$(mktemp -d)"
brew install --cask --appdir="$APPDIR" johnny4young/tap/portavoz
codesign --verify --deep --strict --verbose=2 "$APPDIR/Portavoz.app"
xcrun stapler validate "$APPDIR/Portavoz.app"
spctl -a -vvv -t exec "$APPDIR/Portavoz.app"
brew uninstall --cask --force portavoz
```

The release criterion is one additional clean-machine launch on macOS 15
Sequoia with no previous Portavoz app or Homebrew receipt. If it fails, preserve
the exact output from
`brew install --verbose --debug --cask johnny4young/tap/portavoz`; do not infer
a packaging cause from a paraphrased alert.

## Undo a bad release

```sh
gh release delete v<version> --yes
git push --delete origin v<version>
git tag -d v<version>
```
Then fix and re-run from §3. (The cask bump is a separate commit in the tap repo;
revert it there if it already landed.)

## Hard rules

- **NEVER touch `/Applications/Portavoz.app`** — the author's notarized release
  copy; it updates only via Sparkle/Homebrew. The dev app is
  `/Applications/Portavoz Dev.app` (`make install`).
- No AI co-authorship trailers in the tag, release, or commit messages.
