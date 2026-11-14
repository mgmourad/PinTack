# Installing PinTack with Homebrew

> **Status: not yet possible, and the reason is notarization, not packaging.** The cask is written
> and ready (`packaging/homebrew/pintack.rb`). What it waits on is an Apple Developer ID. This page
> says exactly what has to happen, in order, and what was verified rather than assumed.

---

## The blocker, first

Homebrew **quarantines everything it downloads**, and as of Homebrew 7 there is no longer a
`--no-quarantine` flag to opt out — checked against the Homebrew installed here (7.0.13): the option
appears neither in `brew install --help` nor anywhere in `Library/Homebrew`. Homebrew's
[Acceptable Casks](https://docs.brew.sh/Acceptable-Casks) policy also states that apps Gatekeeper can
assess must pass Homebrew's Gatekeeper checks, and must not require Gatekeeper to be disabled or
bypassed.

PinTack's disk image today is **ad-hoc signed and not notarized**. Installing that through Homebrew
would succeed, and then macOS would refuse to open the app, with no documented way for the cask to
help. So:

**Notarization is a prerequisite for Homebrew, not a nice-to-have.** It is the same prerequisite as
for any other distribution outside this repository, so nothing extra is being asked for.

---

## The order of work

### 1. Apple Developer Program — $99/year

Needed for a Developer ID certificate. A free Apple ID can sign for local use only.

Note the knock-on effect recorded in `CLAUDE.md`: joining changes the **Team ID**, and the WidgetKit
widget's App Group identifier must carry it (`SPEC.md` §11.2). The widget is shelved on exactly this
decision, so doing this unblocks both at once.

### 2. Sign and notarize the disk image

```bash
# Sign the app with your Developer ID, hardened runtime on
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" build/Release/PinTack.app

# Build the image, then notarize and staple it
scripts/make-dmg.sh
xcrun notarytool submit dist/PinTack-0.1.0.dmg --keychain-profile "AC_PASSWORD" --wait
xcrun staple dist/PinTack-0.1.0.dmg

# The check that matters — this is what Gatekeeper will do on someone else's Mac
spctl -a -t open --context context:primary-signature -vv dist/PinTack-0.1.0.dmg
```

`scripts/make-dmg.sh` does not sign or notarize; it builds and styles the image. Signing is a
separate step because it needs credentials that do not belong in a repository.

### 3. Publish a GitHub Release

Tag the release `v0.1.0` and attach the notarized disk image as `PinTack-0.1.0.dmg`. The cask's URL
is built from the tag and the filename, so keeping both predictable is what lets the cask be updated
by changing two lines.

### 4. Generate the cask

```bash
scripts/make-homebrew-cask.sh dist/PinTack-0.1.0.dmg Casks/pintack.rb
```

It reads the version from the app's `Info.plist` inside the image — not from the filename, so a
renamed file cannot publish a cask pointing at a different build — computes the SHA-256, and
**warns if the build is not signed and notarized** rather than letting that be discovered by whoever
runs `brew install` first.

---

## Option A — your own tap (available immediately after notarization)

A tap is just a Git repository. The naming is a Homebrew requirement, not a convention:

> On GitHub, a repository must be named `homebrew-<repository>` to use the one-argument form of
> `brew tap`. — [Homebrew Taps](https://docs.brew.sh/Taps)

So:

1. Create a public repository called **`mgmourad/homebrew-pintack`**.
2. Put the generated cask at **`Casks/pintack.rb`**. (Verified against the taps installed on this
   Mac — `hashicorp/tap` and `oh-my-posh` both keep their casks in a `Casks/` directory.)
3. Users then run:

```bash
brew tap mgmourad/pintack
brew install --cask pintack
```

The `homebrew-` prefix is dropped from the command. Updates are `brew update && brew upgrade --cask pintack`.

To release a new build: regenerate the cask, commit it to the tap, done. No review, no waiting.

**Test it before anyone else does:**

```bash
HOMEBREW_NO_INSTALL_FROM_API=1 brew install --cask pintack
brew uninstall --cask pintack
brew audit --new --cask pintack
brew style --fix --cask pintack
```

---

## Option B — the official `homebrew/cask` repository

This is the one that makes `brew install --cask pintack` work with no tap. It has a bar, and PinTack
does not currently clear it. From Homebrew's
[Package Acceptance Policy](https://docs.brew.sh/Package-Acceptance-Policy), a GitHub project
normally satisfies the notability requirement by meeting one of these thresholds:

| | Threshold |
|---|---|
| Submitted by anyone else | **30 forks, 30 watchers or 75 stars** |
| **Self-submitted** by the repository owner, or by a commit author whose email is at the package's homepage/url domain | **90 forks, 90 watchers or 225 stars** |

The second row is the one that applies here, since you would be submitting your own app. Two further
rules from the same page: a repository **less than 30 days old is normally not eligible**, and a new
package **must have a working `livecheck`**.

Practically: ship through your own tap, let the project gather stars, and submit to `homebrew/cask`
when it clears 225 stars (or 90 forks/watchers). Nothing is lost by starting with a tap — the cask
file is the same file.

---

## What the cask does

`packaging/homebrew/pintack.rb`, in full, is short. Two things in it are deliberate:

- **`depends_on macos: ">= :sonoma"`** — PinTack targets macOS 14, so Homebrew refuses the install
  on older systems rather than letting it fail at launch.
- **The `zap` stanza does not touch your vault.** It removes preferences, caches, WebKit storage and
  application support. Your notes are Markdown files in a folder you chose, and uninstalling an
  editor must never delete the documents it edited. `brew uninstall --zap --cask pintack` leaves
  them exactly where they are.

---

## Summary

| Step | Blocked on | Effort |
|---|---|---|
| Apple Developer Program | a decision and $99/year | an afternoon |
| Sign + notarize | step 1 | scripted above |
| GitHub Release | step 2 | minutes |
| Own tap → `brew install --cask pintack` | step 3 | minutes |
| Official `homebrew/cask` | 225 stars, or 90 forks/watchers | however long that takes |
