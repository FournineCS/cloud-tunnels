import SwiftUI

struct KubectlContextView: View {
    @State private var contexts: [KubeContext] = []
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(contexts.count) context(s)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { reload() }
                    .controlSize(.small)
            }

            if contexts.isEmpty && !loading {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("No kubectl contexts found")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Make sure kubectl is on PATH and ~/.kube/config exists")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(contexts) { ctx in
                            row(ctx)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .onAppear { reload() }
    }

    @ViewBuilder
    private func row(_ ctx: KubeContext) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ctx.isCurrent ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ctx.isCurrent ? Color.green : Color.secondary)
                .font(.system(size: 11))
            Text(ctx.name)
                .font(.system(size: 11, weight: ctx.isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if !ctx.isCurrent {
                Button("Use") {
                    _ = KubectlContext.use(context: ctx.name)
                    reload()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(
            ctx.isCurrent ? Color.green.opacity(0.08) : Color.primary.opacity(0.04)
        ))
    }

    private func reload() {
        loading = true
        DispatchQueue.global().async {
            let result = KubectlContext.list()
            DispatchQueue.main.async {
                contexts = result
                loading = false
            }
        }
    }
}
