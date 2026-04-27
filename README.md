# CloudTunnels (Swift)

Native macOS menu bar app for managing port-forwarding tunnels across **GCP
IAP**, **AWS Session Manager**, and **Cloud SQL Auth Proxy**. Originally a
Python `gcp-iap-tunnel-app` clone; now multi-cloud. Shells out to
`gcloud compute start-iap-tunnel`, `aws ssm start-session`, and
`cloud-sql-proxy` and manages tunnel lifecycle, multi-account auth state,
auto-reconnect, and notifications.

Bundle ID: `com.fourninecloud.cloud-tunnels`. On first launch, config is
auto-migrated from the previous `GCPIAPTunnel` Application Support directory
(and before that, the Python `~/.gcp-iap-tunnels` dotfile) — existing users
keep their tunnels on upgrade.

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ (command line tools provide `swift`)
- For GCP tunnels: `gcloud` CLI on `PATH` (or under `/usr/local/bin`,
  `/opt/homebrew/bin`, `~/google-cloud-sdk/bin`)
- For AWS tunnels: `aws` CLI **and** `session-manager-plugin`. Install with
  `brew install awscli` and follow
  [AWS docs](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
  for the SSM plugin.
- For Cloud SQL Proxy tunnels: `cloud-sql-proxy` v2 on `PATH` (or under
  `/usr/local/bin`, `/opt/homebrew/bin`, `~/bin`). Install with
  `brew install cloud-sql-proxy`, then run
  `gcloud auth application-default login` once to set up ADC.

## Build & run

```bash
cd macos
make test          # swift test
make app           # build Release + package build/CloudTunnels.app
make run           # build + open
make install       # copy to /Applications and strip quarantine
make zip           # build/CloudTunnels.zip (universal)
make zip-arm64     # build/CloudTunnels-arm64.zip  (Apple Silicon)
make zip-x86_64    # build/CloudTunnels-x86_64.zip (Intel)
make zip-all       # both arch zips
```

### Distributing under your own Apple Developer account

Update `APP_BUNDLE_ID` and `HELPER_BUNDLE_ID` in the `Makefile`, then update
`Resources/Info.plist` and `Resources/LaunchDaemons/*.plist` to match, and
set `SIGN_IDENTITY` to your certificate before running `make app`.

## First launch (unsigned)

Because this is an internal unsigned build, Gatekeeper will block it once:

```bash
xattr -dr com.apple.quarantine /Applications/CloudTunnels.app
```

Or right-click the `.app` → **Open** → **Open** in the dialog. After one
approval, future launches work normally.

## Config location

- Primary: `~/Library/Application Support/CloudTunnels/config.json`
- Legacy (read once, migrated on first launch, in order):
  1. `~/Library/Application Support/GCPIAPTunnel/config.json` (pre-rename Swift build)
  2. `~/.gcp-iap-tunnels/config.json` (Python predecessor)

Legacy files are left in place as a rollback. To roll back, delete the
new-location file.

## Logs

All structured logs go to `os.Logger` with subsystem
`com.fourninecloud.cloud-tunnels`. Tail them live with:

```bash
log stream --predicate 'subsystem == "com.fourninecloud.cloud-tunnels"' --info
```

Or open **Console.app** and filter by the subsystem.

## Architecture

| Layer | Files |
|---|---|
| Models | `Sources/TunnelCore/Models/{Tunnel,ProviderConfig,TunnelStatus,Preferences}.swift` |
| Core | `Sources/CloudTunnels/Core/{AuthManager,AWSAuthManager,TunnelManager}.swift` |
| UI | `Sources/CloudTunnels/UI/{MenuBarView,AddEditTunnelView,PreferencesView,HelpView}.swift` |
| Services | `Sources/CloudTunnels/Services/{Notifications,QuickAction}.swift` |
| App entry | `Sources/CloudTunnels/App/CloudTunnelsApp.swift` |
| Tests | `Tests/CloudTunnelsTests/*.swift` |

## Providers

Each saved tunnel is tagged with one of three providers:

### GCP IAP

Wraps `gcloud compute start-iap-tunnel`. Each tunnel can pin to a specific
gcloud account via the **gcloud account** picker, so two tunnels can run under
two different accounts simultaneously without re-logging in. Add accounts with
the **GCP login** button (runs `gcloud auth login`).

### AWS SSM

Wraps `aws ssm start-session`. Two modes:

- **Direct-to-instance**: leave the *Remote host* field blank. Uses the
  `AWS-StartPortForwardingSession` document to forward a port on the target EC2
  itself (e.g. SSH to a bastion).
- **Bastion → remote host**: fill in *Remote host*. Uses the
  `AWS-StartPortForwardingSessionToRemoteHost` document to tunnel through the
  target to a different host like an RDS database.

Each tunnel can pin to a specific AWS CLI profile and override the region. Sign
in to SSO profiles via the **AWS SSO** button (runs `aws sso login --profile=X`).

The app discovers profiles from `aws configure list-profiles` and verifies each
one with `aws sts get-caller-identity --profile=X`. It does **not** edit
`~/.aws/config` — manage profiles via the AWS CLI as usual.

### Cloud SQL Auth Proxy

Wraps `cloud-sql-proxy` v2 for local connections to Cloud SQL instances
(Postgres, MySQL, SQL Server). Uses Application Default Credentials — run
`gcloud auth application-default login` once before connecting. Each tunnel
takes an **instance connection name** in the form `project:region:instance`
plus a local listen port, and exposes toggles for:

- **Use private IP** — passes `--private-ip`, for reaching Cloud SQL over
  VPN/peered networks instead of the public endpoint.
- **Auto IAM authentication** — passes `--auto-iam-authn`, so the proxy
  injects an OAuth token as the DB password for IAM DB users.
- **Impersonate service account** — passes `--impersonate-service-account`
  to run the proxy as a specified service account.

The tunnel reuses the existing **gcloud account** picker; selecting an account
forwards `CLOUDSDK_CORE_ACCOUNT` to `cloud-sql-proxy` so ADC resolves to that
identity. Install the binary with `brew install cloud-sql-proxy`.

## Parity with the Python version

| Feature | Python | Swift |
|---|---|---|
| Menu bar icon with status | rumps emoji | SF Symbol (`cloud` / `cloud.fill`) |
| Add/edit/delete tunnel | PyObjC NSAlert forms | SwiftUI Form in a floating NSWindow |
| Connect/disconnect | `subprocess.Popen` + daemon threads | `Process` wrapped in `TunnelProcess` with `AsyncStream` |
| Stderr parsing | `readline()` in thread | Pipe drain + line splitter |
| "Listening on port" + 15s fallback | yes | yes |
| Auth expiry regex list | 6 patterns | same 6 patterns (`TunnelProcess.authExpiredPatterns`) |
| Auto-reconnect 3×/10s (skip on auth) | yes | yes |
| Port cleanup via `lsof -ti :PORT` | yes | `PortUtil.killHolders` |
| Periodic auth check | daemon thread, 30 min | `Task` with `Task.sleep`, configurable |
| Persisted config | `~/.gcp-iap-tunnels/config.json` | `~/Library/Application Support/CloudTunnels/config.json` with chained migration |

## Smoke test checklist

1. `make test` — all unit tests pass
2. `make run` — icon appears in the menu bar
3. Click **Login** — `gcloud auth login` opens browser, icon updates on success
4. **Add Tunnel…** → fill a real IAP-reachable instance → Save → Start
5. `lsof -i :LOCALPORT` shows the `gcloud` process bound to your local port
6. Click **Stop** → process exits, port freed
7. `gcloud auth revoke <account>` while a tunnel runs → tunnel dies, notification fires, auto-reconnect does **not** kick in
8. Quit the app → `pgrep -f start-iap-tunnel` is empty
