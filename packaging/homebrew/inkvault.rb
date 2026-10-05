# Homebrew formula template for the `inkvault` CLI.
#
# Lives in the tap repository anthonytw/homebrew-tap as Formula/inkvault.rb.
# packaging/homebrew/README.md explains how to fill in VERSION and the checksums
# from a release's SHA256SUMS (or run scripts/update-formula.sh).
class Inkvault < Formula
  desc "Keys, verification, export and recovery for InkVault encrypted handwriting vaults"
  homepage "https://github.com/anthonytw/inkvault"
  version "@VERSION@"
  license "GPL-3.0-or-later"

  on_macos do
    # One universal (arm64 + x86_64) binary.
    url "https://github.com/anthonytw/inkvault/releases/download/v#{version}/inkvault-#{version}-macos-universal.tar.gz"
    sha256 "@SHA256_MACOS_UNIVERSAL@"
  end

  on_linux do
    on_intel do
      url "https://github.com/anthonytw/inkvault/releases/download/v#{version}/inkvault-#{version}-linux-x86_64.tar.gz"
      sha256 "@SHA256_LINUX_X86_64@"
    end
    on_arm do
      url "https://github.com/anthonytw/inkvault/releases/download/v#{version}/inkvault-#{version}-linux-aarch64.tar.gz"
      sha256 "@SHA256_LINUX_AARCH64@"
    end
  end

  def install
    bin.install "inkvault"
    doc.install "README.md", "CHANGELOG.md", "LICENSE-EXCEPTION", "docs/cli.md"
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/inkvault --version").strip
    # A fresh identity is an age secret key.
    assert_match "AGE-SECRET-KEY-", shell_output("#{bin}/inkvault keys generate")
  end
end
