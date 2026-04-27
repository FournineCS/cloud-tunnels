import AppKit
import SwiftUI

/// Kubeconfig Inspector — loads the user's current active
/// kubeconfig (or a pasted one) via kubectl itself and shows the
/// clusters / contexts / users in a flat structured view. Cluster
/// rows highlight any `proxy-url` that CloudTunnels' own SSH
/// tunnel kubeconfigPatch flow has set, so the user can see at a
/// glance which clusters are plumbed through an active tunnel.
struct KubeconfigInspectorView: View {

    enum InputMode: String, CaseIterable, Identifiable {
        case current = "Use current kubeconfig"
        case paste = "Paste a kubeconfig"
        var id: String { rawValue }
    }

    @State private var mode: InputMode = .current
    @State private var pasted: String = ""
    @State private var inspected: KubeconfigInspector.Inspected?
    @State private var errorMessage: String?
    @State private var loading: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                modeSection
                if mode == .paste {
                    pasteInput
                }
                Divider().opacity(0.4)
                output
            }
            .padding(14)
        }
        .onAppear {
            if mode == .current && inspected == nil {
                loadCurrent()
            }
        }
    }

    // MARK: - Sections

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SOURCE")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            Picker("", selection: $mode) {
                ForEach(InputMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: mode) { _ in
                inspected = nil
                errorMessage = nil
                if mode == .current {
                    loadCurrent()
                }
            }
            if mode == .current {
                HStack(spacing: 6) {
                    Button {
                        loadCurrent()
                    } label: {
                        HStack(spacing: 4) {
                            if loading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(loading ? "Loading…" : "Reload")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(loading)
                    Spacer()
                }
            }
        }
    }

    private var pasteInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("KUBECONFIG (YAML or JSON)")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Paste") {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        pasted = s
                        inspect()
                    }
                }
                .controlSize(.small)
                Button("Inspect") { inspect() }
                    .controlSize(.small)
                    .disabled(pasted.isEmpty)
            }
            TextEditor(text: $pasted)
                .font(.system(size: 10, design: .monospaced))
                .frame(minHeight: 100, maxHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
        }
    }

    @ViewBuilder
    private var output: some View {
        if let i = inspected {
            VStack(alignment: .leading, spacing: 12) {
                if i.clusters.isEmpty && i.contexts.isEmpty && i.users.isEmpty {
                    Text("Kubeconfig is empty (no clusters / contexts / users defined).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    clustersSection(i)
                    contextsSection(i)
                    usersSection(i)
                }
            }
        } else if let err = errorMessage {
            Text(err)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if !loading {
            VStack(spacing: 6) {
                Image(systemName: "helm")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No kubeconfig loaded yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    private func clustersSection(_ i: KubeconfigInspector.Inspected) -> some View {
        SectionHeader(title: "CLUSTERS", count: i.clusters.count) {
            ForEach(i.clusters) { cluster in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(cluster.name)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        copyButton(cluster.name)
                    }
                    Text(cluster.server)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let proxy = cluster.proxyURL {
                        Label("proxy-url: \(proxy)", systemImage: "network.badge.shield.half.filled")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                    HStack(spacing: 8) {
                        if cluster.insecureSkipTLSVerify {
                            Label("insecure", systemImage: "exclamationmark.shield")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }
                        if cluster.hasCAData {
                            Label("CA present", systemImage: "checkmark.seal")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(rowBackground(highlighted: cluster.proxyURL != nil))
            }
        }
    }

    private func contextsSection(_ i: KubeconfigInspector.Inspected) -> some View {
        SectionHeader(title: "CONTEXTS", count: i.contexts.count) {
            ForEach(i.contexts) { ctx in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: ctx.isCurrent ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(ctx.isCurrent ? Color.green : .secondary)
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ctx.name)
                            .font(.system(size: 12, weight: ctx.isCurrent ? .bold : .medium))
                        HStack(spacing: 6) {
                            Text("cluster: \(ctx.cluster)")
                            Text("·")
                            Text("user: \(ctx.user)")
                            if let ns = ctx.namespace {
                                Text("·")
                                Text("ns: \(ns)")
                            }
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                    Spacer()
                    copyButton(ctx.name)
                }
                .padding(8)
                .background(rowBackground(highlighted: ctx.isCurrent))
            }
        }
    }

    private func usersSection(_ i: KubeconfigInspector.Inspected) -> some View {
        SectionHeader(title: "USERS", count: i.users.count) {
            ForEach(i.users) { user in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.name)
                            .font(.system(size: 12, weight: .medium))
                        Text(user.authMethod)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    copyButton(user.name)
                }
                .padding(8)
                .background(rowBackground(highlighted: false))
            }
        }
    }

    private func copyButton(_ value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 9))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Copy name")
    }

    private func rowBackground(highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(highlighted ? Color.green.opacity(0.08) : Color.primary.opacity(0.04))
    }

    // MARK: - Actions

    private func loadCurrent() {
        loading = true
        errorMessage = nil
        inspected = nil
        Task {
            let result: Result<KubeconfigInspector.Inspected, Error>
            do {
                let r = try KubeconfigInspector.loadCurrent()
                result = .success(r)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                switch result {
                case .success(let r):
                    self.inspected = r
                case .failure(let e):
                    self.errorMessage = e.localizedDescription
                }
                self.loading = false
            }
        }
    }

    private func inspect() {
        guard !pasted.isEmpty else { return }
        errorMessage = nil
        inspected = nil
        do {
            inspected = try KubeconfigInspector.inspect(pastedConfig: pasted)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SectionHeader<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                content
            }
        }
    }
}
