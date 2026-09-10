# The Homebrew cask, as a template.
#
# It lives here rather than only in the tap so that there is one copy to read
# and edit, and so the tap can be bootstrapped by hand. The release workflow
# fills in the two placeholders and writes the result to Casks/ezdisplay.rb in
# the tap repository, which is what `brew install` reads.
#
# To bootstrap the tap by hand, after a release exists:
#
#     version=1.0.0
#     sha=$(shasum -a 256 EZDisplay-${version}.zip | cut -d' ' -f1)
#     sed -e "s/@VERSION@/${version}/" -e "s/@SHA256@/${sha}/" etc/ezdisplay.rb \
#         > ../homebrew-tap/Casks/ezdisplay.rb
#
# The placeholders are quoted strings, so this file parses as Ruby either way
# and `ruby -c` is a real check on it.

cask "ezdisplay" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/davidnoyes/EZDisplay/releases/download/v#{version}/EZDisplay-#{version}.zip",
      verified: "github.com/davidnoyes/EZDisplay/"
  name "EZDisplay"
  desc "Menu bar app for display resolution, refresh rate, HDR, and color"
  homepage "https://github.com/davidnoyes/EZDisplay"

  livecheck do
    url :url
    strategy :github_latest
  end

  # EZDisplay updates itself from its About panel. This records that, but it no
  # longer keeps `brew upgrade` away: since Homebrew 6.0 an auto-updating cask
  # is upgraded whenever the tap is newer than the version Homebrew reads out of
  # the installed bundle. Measured against 6.0.22, plain `brew upgrade` takes
  # EZDisplay, and no `--greedy` is needed.
  #
  # Reading the bundle rather than its own receipt is what makes that safe, and
  # it is the reason to keep this stanza: after the app has updated itself,
  # Homebrew sees the new version on disk and leaves it alone instead of
  # reinstalling over the top. Anyone who wants Homebrew to keep away entirely
  # sets HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS=1.
  auto_updates true

  depends_on macos: :big_sur
  depends_on arch: :arm64

  app "EZDisplay.app"
  # The same binary the app runs, which takes arguments and does not start the
  # menu bar app when it gets them. Lower case on purpose: matching the
  # binary's own capitalization would work only on a case-insensitive volume.
  binary "#{appdir}/EZDisplay.app/Contents/MacOS/EZDisplay", target: "ezdisplay"

  # The app runs continuously, and an upgrade that replaced the bundle
  # underneath a running copy would leave the old one in the menu bar.
  uninstall quit: "io.github.davidnoyes.ezdisplay"

  zap trash: [
    "~/Library/Application Support/io.github.davidnoyes.ezdisplay",
    "~/Library/Preferences/io.github.davidnoyes.ezdisplay.plist",
  ]

  caveats <<~CAVEATS
    EZDisplay is signed by its own certificate rather than by an Apple one, so
    macOS refuses the first launch. Open System Settings > Privacy & Security,
    find the message naming EZDisplay, and choose Open Anyway. That is once per
    machine: every release is signed by the same certificate.

    To let EZDisplay control the volume keys, grant it Accessibility in
    System Settings > Privacy & Security > Accessibility.
  CAVEATS
end
