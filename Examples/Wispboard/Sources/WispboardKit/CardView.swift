import AppKit
import SwiftUI

struct CardView: View {
    @Environment(BoardStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @AppStorage(SettingsKey.density) private var density = CardDensity.comfortable
    @AppStorage(SettingsKey.remind) private var remind = true
    let card: Card
    let tint: Color
    @Binding var drag: CardDrag?
    let onDrop: (Card.ID, CGPoint) -> Void

    @State private var hovering = false

    private var isSelected: Bool { store.selection == card.id }
    private var isDragging: Bool { drag?.id == card.id }
    private var compact: Bool { density == .compact }
    private var badgeOnTitle: Bool { PlantedBugs.badgeOnTitle(cardID: card.id, selected: isSelected) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            Text(card.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(card.column == .done ? Color.readableSecondary : Color.primary)
                .strikethrough(card.column == .done, color: Color.readableSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("card.\(card.id).title")
                .background(alignment: .bottomTrailing) {
                    if card.due, badgeOnTitle { DueBadge(remind: remind, cardID: card.id) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 18)
            if card.tag != nil || (card.due && !badgeOnTitle) {
                HStack(spacing: 6) {
                    if let tag = card.tag { TagChip(tag: tag, cardID: card.id) }
                    Spacer(minLength: 0)
                    if card.due, !badgeOnTitle { DueBadge(remind: remind, cardID: card.id) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 8 : 12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(scheme == .dark ? Color(white: 0.2) : Color.white)
                .shadow(color: .black.opacity(isDragging ? 0.22 : (scheme == .dark ? 0.35 : 0.08)),
                        radius: isDragging ? 12 : 2, y: isDragging ? 6 : 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(scheme == .dark ? 0.08 : 0.06),
                              lineWidth: isSelected ? 2 : 1)
        }
        .overlay(alignment: .topTrailing) {
            if hovering, drag == nil {
                Button { withAnimation(.snappy(duration: 0.25)) { store.delete(card.id) } } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(L("Delete Card"))
                .accessibilityLabel(L("Delete Card"))
                .accessibilityIdentifier("card.\(card.id).delete")
                .padding(6)
                .transition(.opacity)
            }
        }
        .scaleEffect(isDragging ? 1.03 : 1)
        .rotationEffect(.degrees(isDragging ? 1.5 : 0))
        .offset(isDragging ? drag?.translation ?? .zero : .zero)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture { store.select(card.id) }
        .gesture(dragGesture)
        .animation(.snappy(duration: 0.25), value: isDragging)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { store.select(card.id) }
        .accessibilityIdentifier("card.\(card.id)")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(BoardSpace.name))
            .onChanged { value in
                if drag == nil {
                    drag = CardDrag(id: card.id, from: card.column, location: value.location)
                }
                drag?.translation = value.translation
                drag?.location = value.location
            }
            .onEnded { value in
                drag = nil
                onDrop(card.id, value.location)
            }
    }
}

struct TagChip: View {
    @Environment(\.colorScheme) private var scheme
    let tag: Tag
    let cardID: String

    var body: some View {
        Text(tag.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tag.text(dark: scheme == .dark))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tag.tint.opacity(scheme == .dark ? 0.16 : 0.12), in: Capsule())
            .accessibilityIdentifier("card.\(cardID).tag")
    }
}

struct DueBadge: View {
    @Environment(\.colorScheme) private var scheme
    let remind: Bool
    let cardID: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: remind ? "bell.fill" : "clock.fill")
                .font(.system(size: 9, weight: .bold))
                .accessibilityHidden(true)
            Text(L("Due"))
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(scheme == .dark ? Color(red: 1.0, green: 0.74, blue: 0.45) : Color(red: 0.62, green: 0.30, blue: 0.0))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.orange.opacity(scheme == .dark ? 0.16 : 0.13), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("card.\(cardID).due")
    }
}

extension Color {
    /// Secondary text that stays readable on the board's light and dark backgrounds (the system secondary label is a little light for small text there).
    static let readableSecondary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.70, alpha: 1) : NSColor(white: 0.30, alpha: 1)
    })
}
