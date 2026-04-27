import Foundation

/// Mach service name shared by the GUI app and the privileged proxy helper.
/// Must match the `MachServices` key in the launchd plist embedded inside the
/// app bundle at `Contents/Library/LaunchDaemons/<plist>.plist`.
public enum ProxyHelperMachService {
    public static let name = "com.fourninecloud.cloud-tunnels.proxy-helper"
}
