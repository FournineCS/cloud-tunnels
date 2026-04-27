import Foundation
import os
import ProxyHelperShared

let log = Logger(
    subsystem: "com.fourninecloud.cloud-tunnels.proxy-helper",
    category: "main"
)

log.info("CloudTunnelsProxyHelper starting; mach service: \(ProxyHelperMachService.name, privacy: .public)")

// 1. Build the long-lived helper state (CA, route table, NIO server, etc.).
let context: HelperContext
do {
    context = try HelperContext()
} catch {
    log.error("Failed to initialize HelperContext: \(error.localizedDescription, privacy: .public)")
    FileHandle.standardError.write(
        Data("CloudTunnelsProxyHelper: cannot initialize: \(error)\n".utf8)
    )
    exit(1)
}

// 2. Stand up the NSXPC listener bound to the launchd-registered Mach name.
let service = XPCService(context: context)
let listener = NSXPCListener(machServiceName: ProxyHelperMachService.name)
listener.delegate = service
listener.resume()

log.info("XPC listener resumed; entering run loop")

// 3. Block forever. launchd owns our lifecycle; SIGTERM from launchd will
//    end the process. We do not handle signals explicitly because cleanup
//    happens on uninstall via the XPC `uninstall` call, not on SIGTERM.
RunLoop.main.run()
