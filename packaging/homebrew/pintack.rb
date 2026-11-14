# PinTack's Homebrew cask.
#
# This file is a TEMPLATE: `scripts/make-homebrew-cask.sh` stamps the version and the SHA-256 of a
# built disk image into it and writes the result where your tap can serve it. See docs/HOMEBREW.md
# for what has to be true before it will install cleanly on somebody else's Mac — in short, the app
# has to be notarized, because Homebrew quarantines what it downloads and no longer offers a way to
# opt out.
#
# The cask's filename, and this token, must match: pintack.rb / "pintack".
cask "pintack" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/mgmourad/PinTack/releases/download/v#{version}/PinTack-#{version}.dmg",
      verified: "github.com/mgmourad/PinTack/"
  name "PinTack"
  desc "Sticky notes backed by plain Markdown files"
  homepage "https://github.com/mgmourad/PinTack"

  depends_on macos: ">= :sonoma"

  app "PinTack.app"

  # Everything PinTack writes outside the vault. The vault itself is deliberately NOT listed: it is
  # the user's own Markdown files, in a folder they chose, and uninstalling an editor must never
  # delete the documents it edited.
  zap trash: [
    "~/Library/Application Support/PinTack",
    "~/Library/Caches/io.cymentix.pintack",
    "~/Library/HTTPStorages/io.cymentix.pintack",
    "~/Library/Preferences/io.cymentix.pintack.plist",
    "~/Library/Saved Application State/io.cymentix.pintack.savedState",
    "~/Library/WebKit/io.cymentix.pintack",
  ]
end
