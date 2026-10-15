import SwiftUI

/// The panel on the right: the selected card's title and column.
struct InspectorView: View {
    @Environment(BoardStore.self) private var store
    @AppStorage(SettingsKey.showCompleted) private var showCompleted = true
    @State private var draft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Card"))
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("inspector.heading")
                Spacer()
                Button { store.closeInspector() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help(L("Close"))
                .accessibilityLabel(L("Close"))
                .accessibilityIdentifier("inspector.close")
            }
            .padding(.bottom, 18)

            if let card = store.selectedCard {
                details(card)
            } else {
                emptyState
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .overlay(alignment: .leading) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.panel")
        .onChange(of: store.selection, initial: true) { old, new in
            if let old, old != new { store.rename(old, to: draft) }
            draft = store.selectedCard.map { $0.id == store.freshCardID ? "" : $0.title } ?? ""
        }
        .onChange(of: store.focusTitleRequest, initial: true) { _, request in
            guard request > 0 else { return }
            DispatchQueue.main.async { titleFocused = true }
        }
    }

    @ViewBuilder
    private func details(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel(L("Title"), id: "inspector.titleLabel")
                TextField(text: $draft, prompt: Text(L("Untitled"))) { Text(L("Title")) }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($titleFocused)
                    .onSubmit {
                        store.rename(card.id, to: draft)
                        titleFocused = false
                    }
                    .accessibilityIdentifier("inspector.title")
            }
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel(L("Column"), id: "inspector.columnLabel")
                Picker(selection: Binding(get: { card.column }, set: { c in withAnimation(.snappy(duration: 0.3)) { store.move(card.id, to: c) } })) {
                    ForEach(showCompleted ? Column.allCases : [.today, .next]) { column in
                        Label(column.title, systemImage: column.symbol).tag(column)
                    }
                } label: {
                    Text(L("Column"))
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("inspector.column")
            }
            if card.tag != nil || card.due {
                HStack(spacing: 6) {
                    if let tag = card.tag { TagChip(tag: tag, cardID: "inspector") }
                    if card.due { DueBadge(remind: true, cardID: "inspector") }
                }
            }
        }
    }

    private func fieldLabel(_ text: String, id: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.readableSecondary)
            .accessibilityIdentifier(id)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(L("No card selected"))
                .font(.headline)
                .foregroundStyle(Color.readableSecondary)
                .accessibilityIdentifier("inspector.emptyTitle")
            Text(L("Select a card to see its details."))
                .font(.callout)
                .foregroundStyle(Color.readableSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("inspector.emptyHint")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
