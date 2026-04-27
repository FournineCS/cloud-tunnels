import AppKit
import SwiftUI

struct JSONFormatterView: View {
    @State private var input: String = ""
    @State private var output: String = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 10) {
            ScrollView {
                TextEditor(text: $input)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 100)
            }
            .frame(maxHeight: 120)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))

            HStack(spacing: 6) {
                Button("Format") { format(pretty: true) }
                Button("Minify") { format(pretty: false) }
                Button("Clear") { input = ""; output = ""; error = nil }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                .disabled(output.isEmpty)
            }
            .controlSize(.small)

            if let error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                Text(output)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
        .padding(12)
    }

    private func format(pretty: Bool) {
        guard let data = input.data(using: .utf8) else { error = "Empty input"; return }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            var opts: JSONSerialization.WritingOptions = [.sortedKeys]
            if pretty { opts.insert(.prettyPrinted) }
            let formatted = try JSONSerialization.data(withJSONObject: obj, options: opts)
            output = String(data: formatted, encoding: .utf8) ?? ""
            error = nil
        } catch let e as NSError {
            output = ""
            error = e.localizedDescription
        }
    }
}
