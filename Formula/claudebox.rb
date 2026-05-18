class Claudebox < Formula
  desc "Claude Code container runtime — scoped per project, runs in Docker or Apple Container"
  homepage "https://github.com/bpeterme/claudebox"
  url "https://github.com/bpeterme/claudebox/archive/refs/tags/PLACEHOLDER.tar.gz"
  sha256 "PLACEHOLDER"
  license "MIT"

  head "https://github.com/bpeterme/claudebox.git", branch: "dev"

  depends_on :macos
  depends_on "jq"

  def install
    version_str = build.head? ? `git describe --tags --always`.chomp : version.to_s
    inreplace "cbox.sh", '_CBOX_VERSION="dev"', "_CBOX_VERSION=\"#{version_str}\""
    bin.install "cbox.sh" => "cbox"
    (share/"claudebox").install "dockerfile"
  end

  def caveats
    <<~EOS
      claudebox requires Apple Container (macOS) or Docker to run containers.

      Build the container image before first use:
        cbox rebuild
    EOS
  end

  test do
    output = shell_output("#{bin}/cbox version")
    assert_match version.to_s, output
  end
end
