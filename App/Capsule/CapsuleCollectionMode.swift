import SwiftUI

enum CapsuleCollectionMode: String, CaseIterable, Identifiable {
    case cards
    case list

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .cards: "rectangle.grid.2x2"
        case .list: "list.bullet"
        }
    }
}

struct CapsuleCollectionModePicker: View {
    @Binding var selection: CapsuleCollectionMode

    var body: some View {
        Picker("View", selection: $selection) {
            ForEach(CapsuleCollectionMode.allCases) { mode in
                Label(mode.title, systemImage: mode.symbol)
                    .labelStyle(.iconOnly)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 78)
        .help("Switch between cards and list")
        .accessibilityLabel("Resource view")
    }
}
