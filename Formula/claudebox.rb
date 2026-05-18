class Claudebox < Formula
  desc "Claude Code container runtime — scoped per project, runs in Docker or Apple Container"
  homepage "https://github.com/bpeterme/claudebox"
  url "https://github.com/bpeterme/claudebox/archive/refs/tags/PLACEHOLDER.tar.gz"
  sha256 "PLACEHOLDER"
  license "MIT"

  depends_on :macos
  depends_on "bash"
  depends_on "jq"

  def install
    bin.install "cbox.sh" => "cbox"
    (share/"claudebox").install "dockerfile"
  end

  def caveats
    <<~EOS
      Build the container image before first use:
        cbox rebuild
    EOS
  end

  test do
    output = shell_output("#{bin}/cbox version")
    assert_match version.to_s, output
  end
end
