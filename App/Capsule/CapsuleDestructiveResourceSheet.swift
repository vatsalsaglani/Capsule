import SwiftUI

struct CapsuleResourcePreviewGroup: Identifiable {
    let title: String
    let systemImage: String
    let names: [String]
    let note: String?

    var id: String { title }

    init(_ title: String, systemImage: String, names: [String], note: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.names = names
        self.note = note
    }
}

struct CapsuleDestructiveResourceSheet: View {
    let title: String
    let message: String
    let actionTitle: String
    let groups: [CapsuleResourcePreviewGroup]
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(group.title, systemImage: group.systemImage)
                                    .font(.headline)
                                Spacer()
                                CapsuleBadge("\(group.names.count)")
                            }
                            if let note = group.note {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if group.names.isEmpty {
                                Text("None")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                            } else {
                                ForEach(group.names, id: \.self) { name in
                                    Label(name, systemImage: "minus.circle")
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(14)
                        .background(CapsulePalette.surface, in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(CapsulePalette.hairline))
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(actionTitle, role: .destructive) {
                    confirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(groups.allSatisfy { $0.names.isEmpty })
            }
        }
        .padding(22)
        .frame(minWidth: 580, minHeight: 430)
    }
}
