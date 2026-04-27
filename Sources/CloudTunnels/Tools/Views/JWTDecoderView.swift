import AppKit
import SwiftUI

struct JWTDecoderView: View {
    @State private var raw: String = ""
    @State private var parsed: JWTSegments?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("JWT").font(.system(size: 9, weight: .semibold)).tracking(0.4).foregroundStyle(.secondary)
            ScrollView {
                TextEditor(text: $raw)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 70)
            }
            .frame(maxHeight: 90)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))

            HStack(spacing: 6) {
                Button("Decode") { decode() }
                Button("Clear") { raw = ""; parsed = nil; error = nil }
                Spacer()
                if let parsed, parsed.isExpired {
                    Label("Expired", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
            .controlSize(.small)

            if let error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }

            if let parsed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        section("HEADER", body: parsed.headerJSON)
                        section("PAYLOAD", body: parsed.payloadJSON)
                        if let exp = parsed.expiry {
                            Text("Expires: \(exp.formatted())")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        if let iat = parsed.issuedAt {
                            Text("Issued: \(iat.formatted())")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func section(_ label: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.4).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(body, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Text(body)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
        }
    }

    private func decode() {
        do {
            parsed = try JWTParser.parse(raw)
            error = nil
        } catch {
            parsed = nil
            self.error = error.localizedDescription
        }
    }
}
