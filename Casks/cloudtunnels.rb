cask "cloudtunnels" do
  version "1.0.2"
  sha256 "eb715a188760add3c229137a85962527bffb306fdfa8972bdb387273294fbd6d"

  url "https://github.com/FournineCS/cloud-tunnels/releases/download/v#{version}/CloudTunnels.zip"
  name "CloudTunnels"
  desc "Native macOS menu bar app for managing GCP IAP, AWS SSM, Cloud SQL Proxy, and SSH tunnels"
  homepage "https://github.com/FournineCS/cloud-tunnels"

  depends_on macos: ">= :ventura"

  app "CloudTunnels.app"

  zap trash: [
    "~/Library/Application Support/CloudTunnels",
    "~/Library/Preferences/com.fourninecloud.cloud-tunnels.plist",
    "~/Library/Logs/CloudTunnels",
  ]
end
