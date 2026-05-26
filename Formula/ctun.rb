class Ctun < Formula
  desc "CLI for managing GCP IAP, AWS SSM, Cloud SQL Proxy, and SSH port-forwarding tunnels"
  homepage "https://github.com/FournineCS/cloud-tunnels"
  url "https://github.com/FournineCS/cloud-tunnels/releases/download/v1.0.2/ctun-universal.tar.gz"
  sha256 "9a35a0a1621f05b6ec4fc305d78ff0da26e7466a5be2129d9441c4c1216aaafb"
  version "1.0.2"
  license "MIT"

  depends_on :macos

  def install
    bin.install "ctun"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/ctun --version 2>&1")
  end
end
