import Foundation
import os

extension Logger {
    public static let subsystem = "com.fourninecloud.cloud-tunnels"
    public static let app = Logger(subsystem: subsystem, category: "app")
}
