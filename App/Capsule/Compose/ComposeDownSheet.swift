import ComposeRuntime
import SwiftUI

struct ComposeDownSheet: View {
    let projectName: String
    let preview: ComposeDownPreview
    let confirm: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var deleteVolumes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Take \(projectName) down?")
                        .font(.title2.weight(.semibold))
                    Text("Review the exact Capsule-owned resources before anything changes.")
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    resourceGroup("Containers", systemImage: "shippingbox", names: preview.containers, disposition: "Stop and delete")
                    resourceGroup("Networks", systemImage: "network", names: preview.networks, disposition: "Delete")
                    resourceGroup(
                        "Volumes",
                        systemImage: "externaldrive",
                        names: preview.volumes,
                        disposition: deleteVolumes ? "Permanently delete data" : "Keep data"
                    )
                }
            }

            Toggle("Delete project volumes and their stored data", isOn: $deleteVolumes)
                .tint(Color(nsColor: .systemRed))
                .disabled(preview.volumes.isEmpty)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(deleteVolumes ? "Down and Delete Volumes" : "Down Project", role: .destructive) {
                    confirm(deleteVolumes)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview.containers.isEmpty && preview.networks.isEmpty && (!deleteVolumes || preview.volumes.isEmpty))
            }
        }
        .padding(22)
        .frame(minWidth: 600, minHeight: 500)
    }

    private func resourceGroup(
        _ title: String,
        systemImage: String,
        names: [String],
        disposition: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
                CapsuleBadge("\(names.count)")
                Text(disposition)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(title == "Volumes" && deleteVolumes ? Color(nsColor: .systemRed) : .secondary)
            }
            if names.isEmpty {
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(names, id: \.self) { name in
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
