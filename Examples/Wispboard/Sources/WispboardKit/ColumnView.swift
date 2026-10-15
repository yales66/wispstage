import SwiftUI

struct ColumnView: View {
    @Environment(BoardStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let column: Column
    @Binding var drag: CardDrag?
    let isDropTarget: Bool
    let onDrop: (Card.ID, CGPoint) -> Void

    var body: some View {
        let cards = store.cards(in: column)
        VStack(alignment: .leading, spacing: 12) {
            header(count: cards.count)
            VStack(spacing: 10) {
                ForEach(cards) { card in
                    CardView(card: card, tint: column.tint, drag: $drag, onDrop: onDrop)
                        .zIndex(drag?.id == card.id ? 1 : 0)
                        .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                }
                if cards.isEmpty { emptyState }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.035))
                .overlay(alignment: .top) {
                    // A faint wash of the column's color behind the header.
                    LinearGradient(colors: [column.tint.opacity(scheme == .dark ? 0.16 : 0.12), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 90)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isDropTarget ? column.tint.opacity(0.8) : Color.primary.opacity(0.05), lineWidth: isDropTarget ? 2 : 1)
        }
        .animation(.snappy(duration: 0.2), value: isDropTarget)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("column.\(column.rawValue)")
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: column.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(column.tint)
                .accessibilityHidden(true)
            Text(column.title)
                .font(.headline)
                .accessibilityIdentifier("column.\(column.rawValue).title")
            Spacer(minLength: 4)
            Text(count, format: .number)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(column.tint.opacity(scheme == .dark ? 0.22 : 0.14), in: Capsule())
                .accessibilityIdentifier("column.\(column.rawValue).count")
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var emptyState: some View {
        Text(L("No cards"))
            .font(.callout)
            .foregroundStyle(Color.readableSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.quaternary)
            }
            .accessibilityIdentifier("column.\(column.rawValue).empty")
    }
}
