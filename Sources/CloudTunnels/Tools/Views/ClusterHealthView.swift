import AppKit
import SwiftUI

/// Cluster Health Checker — probe every context in the user's
/// kubeconfig, show reachable/unreachable with server version or
/// a summarized error. Directly validates that SSH tunnels with
/// kubeconfigPatch are actually giving kubectl access to the
/// private clusters they're patching.
struct ClusterHealthView: View {
    @State private var results: [ClusterHealthChecker.ContextHealth] = []
    @State private var probing: Bool = false
    @State private var hasRun: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider().opacity(0.4)
                body(content)
            }
            .padding(14)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                Task { await runProbe() }
            } label: {
                HStack(spacing: 4) {
                    if probing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "network.badge.shield.half.filled")
                    }
                    Text(probing ? "Probing…" : "Probe all contexts")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(probing)

            Spacer()

            if hasRun && !probing {
                let reachable = results.filter { $0.reachable }.count
                Text("\(reachable) / \(results.count) reachable")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(reachable == results.count ? .green : .secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if probing && results.isEmpty {
            HStack {
                ProgressView().controlSize(.small)
                Text("Running `kubectl version` against each context…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else if !results.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(results) { health in
                    row(health)
                }
            }
        } else if hasRun {
            Text("No contexts found in kubeconfig.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Click “Probe all contexts” to check every kubeconfig context.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    private func row(_ h: ClusterHealthChecker.ContextHealth) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(h.reachable ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(h.context)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let v = h.serverVersion {
                        Text(v)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                }
                Text(h.cluster)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let err = h.errorSummary {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                Task { await reProbe(h) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Re-probe this context")
            .disabled(probing)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill((h.reachable ? Color.green : Color.red).opacity(0.06))
        )
    }

    @ViewBuilder
    private func body(_ inner: some View) -> some View {
        inner
    }

    // MARK: - Actions

    private func runProbe() async {
        probing = true
        hasRun = true
        // Keep old results visible during re-probe so the UI
        // doesn't flash empty.
        let fresh = await ClusterHealthChecker.probeAll()
        results = fresh
        probing = false
    }

    private func reProbe(_ existing: ClusterHealthChecker.ContextHealth) async {
        // Re-probe just this one context without wiping the rest.
        let updated = ClusterHealthChecker.probe(
            context: existing.context,
            cluster: existing.cluster
        )
        if let idx = results.firstIndex(where: { $0.id == existing.id }) {
            results[idx] = updated
        }
    }
}
