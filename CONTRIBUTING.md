# Contributing to CloudTunnels

## Prerequisites

- macOS 13+
- Xcode 15+ (Swift 5.9)
- CLI tools: `gcloud`, `aws`, `kubectl` (only needed for manual testing, not for `make test`)

## Getting started

```bash
git clone https://github.com/sampathinturi/cloud-tunnels.git
cd cloud-tunnels
make test   # must pass before you open a PR
```

## Workflow

1. Fork the repo and create a branch (`git checkout -b feat/my-feature`)
2. Make your changes
3. Run `make test` — all tests must pass
4. Open a pull request against `main`

## Adding a new tunnel provider

The system is built around a **tagged union `ProviderConfig` enum** paired with a **`TunnelLauncher` protocol**. Touch these eight sites in order:

1. `Sources/TunnelCore/Models/ProviderConfig.swift` — new `TunnelProvider` case + config struct + `Codable`/`kind`/`targetDescription`/`accountTag` switches
2. `Sources/TunnelCore/Models/Tunnel.swift` — `accountKey`, `validate()`, and `allLocalPorts()` switches
3. `Sources/TunnelCore/<Name>Launcher.swift` (new) — implement `TunnelLauncher`
4. `Sources/TunnelCore/TunnelLauncher.swift` — add `LauncherFactory.launcher(for:)` case
5. `Sources/CloudTunnels/Core/TunnelManager.swift` — only if the provider needs lifecycle side effects
6. `Sources/CloudTunnels/UI/AddEditTunnelView.swift` — per-provider `@State`, form branch, `<name>Fields` ViewBuilder, `save()` case
7. `Sources/CloudTunnels/UI/MenuBarView.swift` — tab button + three exhaustive switches
8. `Tests/CloudTunnelsTests/<Name>LauncherTests.swift` — mirror `SSHLauncherTests` as template

See `CLAUDE.md` for full details on each site.

## Adding a tool (Tools tab)

Tools are registered in `Sources/CloudTunnels/Tools/Tool.swift` (`ToolRegistry.all`) and dispatched in `Sources/CloudTunnels/Tools/ToolsRootView.swift`. Pattern: pure helper (no SwiftUI, testable) + thin SwiftUI view + tests. Wrap the view body in `ScrollView` to prevent popover footer overlap.

## Code style

- No comments unless the *why* is non-obvious — well-named identifiers carry the what
- Immutable patterns: create new values instead of mutating in place
- Functions under 50 lines, files under 800 lines
- New providers and tools need launcher argument tests; pure argv builders must be unit-tested without shelling out

## Signing

Ad-hoc signing (`SIGN_IDENTITY=-`) is the default and is fine for all changes that don't touch privacy-sensitive frameworks (Calendar, Contacts, Photos, etc.). For those, you'll need a real Apple Developer identity — see the `SIGN_IDENTITY` note in the `Makefile`.

## Tests

`make test` runs the full XCTest suite (~365 tests). No real `kubectl`, `gcloud`, or `aws` invocations happen in tests. Use `swift test --filter <ClassName>` to run a single class.
