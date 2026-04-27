import SwiftUI

struct PortInspectorView: View {
    @State private var portText: String = ""
    @State private var listeners: [PortListener] = []
    @State private var error: String?
    @State private var hasSearched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                TextField("Port (e.g. 5432)", text: $portText, onCommit: lookup)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .frame(width: 160)
                Button("Inspect") { lookup() }
                    .controlSize(.small)
                Spacer()
            }

            if let error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }

            if hasSearched && listeners.isEmpty && error == nil {
                Text("No process listening on port \(portText)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(listeners) { l in
                        listenerRow(l)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func listenerRow(_ l: PortListener) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(l.processName)
                    .font(.system(size: 11, weight: .semibold))
                Text("PID \(l.pid) · \(l.user)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                PortLookup.kill(pid: l.pid)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { lookup() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                    Text("Kill")
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(.red)
                .background(Capsule().fill(Color.red.opacity(0.14)))
                .overlay(Capsule().stroke(Color.red.opacity(0.3), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04)))
    }

    private func lookup() {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(port) else {
            error = "Enter a valid port number 1-65535"
            listeners = []
            hasSearched = true
            return
        }
        error = nil
        listeners = PortLookup.listeners(onPort: port)
        hasSearched = true
    }
}
