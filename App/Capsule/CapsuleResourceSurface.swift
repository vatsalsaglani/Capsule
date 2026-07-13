import SwiftUI

enum CapsuleResourceSurfaceLayout: Equatable {
    case card
    case row
}

/// Shared hover, press, focus, and selected treatment for every resource.
/// The primary content is a real Button; action buttons are siblings, so
/// there are no nested controls and keyboard/VoiceOver behavior stays native.
struct CapsuleResourceSurface<Content: View, Actions: View>: View {
    let layout: CapsuleResourceSurfaceLayout
    let isSelected: Bool
    let accessibilityLabel: String
    let select: () -> Void
    let content: Content
    let actions: Actions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    init(
        layout: CapsuleResourceSurfaceLayout,
        isSelected: Bool,
        accessibilityLabel: String,
        select: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.layout = layout
        self.isSelected = isSelected
        self.accessibilityLabel = accessibilityLabel
        self.select = select
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        Group {
            switch layout {
            case .card:
                VStack(alignment: .leading, spacing: 0) {
                    selectionButton
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                    Divider().opacity(0.65)
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        actions
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 38)
                    .opacity(showsActions ? 1 : 0.28)
                }
            case .row:
                HStack(spacing: 8) {
                    selectionButton
                        .padding(.vertical, 9)
                        .padding(.leading, 12)
                    actions
                        .padding(.trailing, 8)
                        .opacity(showsActions ? 1 : 0)
                }
                .frame(minHeight: 54)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: layout == .card ? 12 : 9, style: .continuous)
                .fill(CapsulePalette.selectionFill(isSelected: isSelected, isHovered: isHovered))
        )
        .overlay(
            RoundedRectangle(cornerRadius: layout == .card ? 12 : 9, style: .continuous)
                .stroke(CapsulePalette.selectionStroke(isSelected: isSelected, isHovered: isHovered), lineWidth: isSelected ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(layout == .card && isHovered ? 0.12 : 0), radius: 8, y: 3)
        .scaleEffect(isHovered && layout == .card && !reduceMotion ? 1.008 : 1)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : CapsuleMotion.standard) {
                isHovered = hovering
            }
        }
        .animation(reduceMotion ? nil : CapsuleMotion.standard, value: isSelected)
    }

    private var selectionButton: some View {
        Button(action: select) {
            content
                .contentShape(.rect)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(CapsulePressButtonStyle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var showsActions: Bool { isHovered || isSelected }
}
