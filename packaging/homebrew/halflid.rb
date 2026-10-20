# DRAFT, never run. It points at the 0.1.0 release and carries the checksum GitHub shows for that zip, but it has not been
# audited or installed with Homebrew, and no tap exists yet.
#
# This is not meant for homebrew/cask. That repository requires casks to pass Gatekeeper (signed and notarized) and
# disables the ones that do not, and Half Lid is signed ad hoc. It is meant for a personal tap: a repository named
# `homebrew-halflid` holding this file as `Casks/halflid.rb`, installed with
#
#   brew install --cask fedebartoli/halflid/halflid
#
# (Homebrew 6 asks the user to trust a third-party tap before it installs from it.)
#
# For a new version: build the zip with `scripts/package.sh`, attach it to a release, then put the version and the SHA-256 from
# `build/dist/HalfLid-<version>.zip.sha256` below. Before it goes into a tap, test it for real: `brew audit --cask --online`,
# install, open, uninstall, and check that nothing is left behind.
cask "halflid" do
  version "0.1.0"
  sha256 "4a720e909723ef0efa4b1e288d0fae5cc99122a565c529ba8a8fd52134a88ccf"

  url "https://github.com/fedebartoli/halflid/releases/download/v#{version}/HalfLid-#{version}.zip"
  name "Half Lid"
  desc "Keeps the Mac awake with the lid closed while coding agents work"
  homepage "https://github.com/fedebartoli/halflid"

  depends_on macos: ">= :sonoma"

  app "HalfLid.app"
  # The command-line tool (`halflid status|start|stop|repair`) lives inside the app.
  binary "#{appdir}/HalfLid.app/Contents/MacOS/halflid"

  # The app is not notarized. Without this, a first launch of the downloaded copy is refused and the user has to find
  # "Open Anyway" in System Settings. Clearing the flag is what building from source gives anyway.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/HalfLid.app"]
  end

  uninstall quit: "io.github.fedebartoli.halflid.menubar"

  zap trash: "~/Library/Application Support/HalfLid"
end
