import AppCore
import Diagnostics
import SwiftUI
import UniformTypeIdentifiers

struct LocalDiagnosticsHistoryView: View {
    let store: DiagnosticsStore

    @State private var exportDocument = DiagnosticExportDocument(data: Data())
    @State private var isExporting = false
    @State private var isConfirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            records
            if let error = store.historyError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
        }
        .padding(16)
        .background(CapsulePalette.surface, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(CapsulePalette.hairline)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "capsule-diagnostics"
        ) { _ in }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Local Diagnostics")
                    .font(.headline)
                Text("Capsule stores only bounded, structured incident categories on this Mac. It never stores stderr, commands, environment values, project names, paths, or crash stacks, and it never uploads anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Export", systemImage: "square.and.arrow.up", action: export)
                .disabled(store.history.totalCount == 0)
            Button("Clear", systemImage: "trash", role: .destructive) {
                isConfirmingClear = true
            }
            .disabled(store.history.totalCount == 0)
            .confirmationDialog(
                "Clear Local Diagnostic History?",
                isPresented: $isConfirmingClear
            ) {
                Button("Clear History", role: .destructive) {
                    Task { await store.clearHistory() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes Capsule's bounded local incident history. It does not change Apple container runtime logs.")
            }
        }
    }

    @ViewBuilder
    private var records: some View {
        if store.history.records.isEmpty {
            Text("No local incidents recorded.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(store.history.records) { record in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: record.kind == .uncleanTermination
                        ? "exclamationmark.triangle.fill"
                        : "xmark.circle.fill")
                        .foregroundStyle(record.severity == .error
                            ? Color(nsColor: .systemRed)
                            : Color(nsColor: .systemOrange))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: record))
                            .font(.callout.weight(.medium))
                        Text("\(record.component.rawValue) · \(record.operation.rawValue)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(record.occurredAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if store.history.omittedCount > 0 {
                Text("\(store.history.omittedCount) older records omitted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func export() {
        Task {
            guard let export = await store.makeExport() else { return }
            exportDocument = DiagnosticExportDocument(data: export.data)
            isExporting = true
        }
    }

    private func title(for record: LocalDiagnosticRecord) -> String {
        switch record.kind {
        case .uncleanTermination: "Capsule did not terminate cleanly"
        case .binaryMissing: "Container CLI was unavailable"
        case .unsupportedRuntime: "Runtime version was unsupported"
        case .runtimeUnavailable: "Runtime was unavailable"
        case .commandFailed: "Runtime command failed"
        case .decodingFailed: "Runtime response could not be read"
        case .networkUnavailable: "Release metadata was unavailable"
        case .persistenceFailed: "Local state could not be saved"
        case .unexpectedFailure: "Unexpected operation failure"
        }
    }
}
