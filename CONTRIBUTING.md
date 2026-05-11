# Contributing to CloudTunnels

Thanks for your interest in CloudTunnels! This document covers the day-to-day
mechanics of contributing. By participating you agree to abide by the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Prerequisites

- macOS 13+
- Xcode 15+ (Swift 5.9)
- CLI tools: `gcloud`, `aws`, `kubectl` (only needed for manual testing, not for `make test`)

## Getting started

```bash
git clone https://github.com/FournineCS/cloud-tunnels.git
cd cloud-tunnels
make test   # must pass before you open a PR
```

## Workflow

1. Fork the repo and create a branch (`git checkout -b feat/my-feature`)
2. Make your changes
3. Run `make test` — all tests must pass
4. For UI / bundle / resource changes, also run `make app && open build/CloudTunnels.app` and confirm the app actually launches (see [Release process](#release-process) for why this matters)
5. Open a pull request against `main`

## Commit messages and PR titles

We follow Conventional Commits. The commit/PR title prefix drives changelog
categorization and tooling:

| Prefix | Use for |
|---|---|
| `feat:` | User-visible new feature |
| `fix:` | User-visible bug fix |
| `refactor:` | Internal change with no behavior change |
| `docs:` | Documentation only |
| `test:` | Tests only |
| `ci:` / `build:` | CI workflow or build-system changes |
| `chore:` | Tooling, deps, housekeeping |

Examples:
- `feat(ssh): support multiple -L forwards per tunnel`
- `fix(branding): load PNGs via Bundle.main, not SwiftPM Bundle.module`
- `ci(release): notarize per-arch zips before stapling`

Keep the subject line under 72 characters. Use the body for the *why* — the
diff already shows the *what*.

## Reporting bugs / asking questions

- **Bugs and feature requests** — open an issue at <https://github.com/FournineCS/cloud-tunnels/issues>. Include macOS version (`sw_vers`), CPU arch (`uname -m`), CloudTunnels version (`About` menu or `ctun --version`), and the relevant slice of `log stream --predicate 'subsystem == "com.fourninecloud.cloud-tunnels"' --info`.
- **Security issues** — please do *not* file a public issue. Email the maintainers privately first.

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

Pure argv builders, config parsers, and reducer-style helpers are the primary
unit-test targets — anything that shells out should be factored into a pure
static function and tested without spawning a process.

## Release process

Releases are tag-driven. Pushing a tag matching `v*` triggers
`.github/workflows/release.yml`, which builds universal + per-arch zips,
signs with the FOURNINE Developer ID, notarizes via `notarytool`, staples,
and publishes a GitHub Release with `SHA256SUMS.txt`.

Before tagging:

1. `make test` — full suite green
2. `make app && open build/CloudTunnels.app` — **confirm the app actually launches and the menu-bar icon appears.** A green build does not guarantee a working `.app`; SwiftPM resource bundles, code-signing entitlements, and TCC requirements only surface at launch. The v1.0.1 release shipped a fatal crash because this step was skipped.
3. Update relevant docs (`README.md`, `CLAUDE.md`) if behavior changed.
4. Tag: `git tag -a vX.Y.Z -m "Release vX.Y.Z" && git push public vX.Y.Z`
5. Watch the run: `gh run watch <run-id> --repo FournineCS/cloud-tunnels --exit-status`

If a release ships with a runtime bug, do **not** retag the same version —
cut a patch release (`vX.Y.(Z+1)`) so anyone who already downloaded the
broken build can tell what they have.

Versioning is [SemVer](https://semver.org/):
- `MAJOR` — incompatible config schema or CLI changes
- `MINOR` — new provider, new tool, new user-visible feature
- `PATCH` — bug fixes, doc updates, build-system fixes
