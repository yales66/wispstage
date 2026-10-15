import AppKit
import SwiftUI

/// The board window: summary line, three columns, and the inspector on the right.
struct BoardView: View {
    @Environment(BoardStore.self) private var store
    @AppStorage(SettingsKey.showCompleted) private var showCompleted = true

    /// Column frames in the board's coordinate space, for finding the column under a dragged card.
    @State private var columnFrames: [Column: CGRect] = [:]
    @State private var drag: CardDrag?

    private var columns: [Column] { showCompleted ? Column.allCases : [.today, .next] }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                DueSummary(count: store.dueCount)
                HStack(alignment: .top, spacing: 14) {
                    ForEach(columns) { column in
                        ColumnView(column: column, drag: $drag, isDropTarget: drag?.target == column && drag?.from != column,
                                   onDrop: drop)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BoardSpace.name)) } action: {
                                columnFrames[column] = $0
                            }
                            .zIndex(drag?.from == column ? 1 : 0)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: BoardSpace.name)
            .contentShape(Rectangle())
            .onTapGesture { store.select(nil) }
            .onChange(of: drag?.location) { _, location in
                guard let location else { return }
                drag?.target = column(at: location)
            }

            if store.inspectorShown {
                InspectorView()
                    .frame(width: 280)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(PlantedBugs.inspectorAnimation, value: store.inspectorShown)
        .background(BoardBackground())
        .navigationTitle("Wispboard")
        .toolbar { BoardToolbar() }
        .background(DeleteKeyHandler(enabled: !PlantedBugs.deleteKeyUnhandled) { store.deleteSelection() })
        .onChange(of: showCompleted) { _, show in
            if !show, store.selectedCard?.column == .done { store.select(nil) }
        }
    }

    private func column(at point: CGPoint) -> Column? {
        columns.first { columnFrames[$0]?.contains(point) ?? false }
    }

    private func drop(_ id: Card.ID, at location: CGPoint) {
        if let target = column(at: location) {
            withAnimation(.snappy(duration: 0.3)) { store.move(id, to: target) }
        }
    }
}

enum BoardSpace {
    static let name = "board"
}

/// A card being dragged: which card, where it came from, and the column under the pointer.
struct CardDrag: Equatable {
    var id: Card.ID
    var from: Column
    var translation: CGSize = .zero
    var location: CGPoint
    var target: Column?
}

struct BoardBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .windowBackgroundColor))
            .ignoresSafeArea()
    }
}

struct DueSummary: View {
    let count: Int
    /// The count when the board opened (the planted placeholder bug shows up only once the count changes).
    @State private var countAtLaunch: Int?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.readableSecondary)
                .accessibilityIdentifier("board.dueSummary")
        }
        .padding(.leading, 2)
        .onAppear { if countAtLaunch == nil { countAtLaunch = count } }
    }

    private var text: String {
        if PlantedBugs.rawSummaryTemplate, let countAtLaunch, count != countAtLaunch { return PlantedBugs.summaryTemplate }
        return String(localized: "\(count) cards due today", bundle: .strings)
    }
}

struct BoardToolbar: ToolbarContent {
    @Environment(BoardStore.self) private var store

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { store.newCard() } label: {
                Label(L("New Card"), systemImage: "plus")
            }
            .help(L("New Card"))
            .accessibilityIdentifier("board.newCard")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Text(store.sync.text)
                .font(.callout)
                .foregroundStyle(Color.readableSecondary)
                .fixedSize()
                .padding(.horizontal, 6)
                .accessibilityIdentifier("board.syncStatus")
            Button { store.startSync() } label: {
                Label(L("Sync"), systemImage: "arrow.triangle.2.circlepath")
            }
            .help(L("Sync"))
            .disabled(store.sync == .syncing)
            .accessibilityIdentifier("board.sync")
            Button { store.toggleInspector() } label: {
                Label(L("Show Inspector"), systemImage: "sidebar.right")
            }
            .help(L("Show Inspector"))
            .accessibilityIdentifier("board.toggleInspector")
        }
    }
}

/// ⌫ deletes the selected card, unless a text field is being edited.
struct DeleteKeyHandler: NSViewRepresentable {
    let enabled: Bool
    let delete: @MainActor () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.update(enabled: enabled, delete: delete)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(enabled: enabled, delete: delete)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.update(enabled: false, delete: nil)
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        private var monitor: Any?
        private var delete: (@MainActor () -> Bool)?

        func update(enabled: Bool, delete: (@MainActor () -> Bool)?) {
            self.delete = delete
            if enabled, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    let key = KeyPress(code: event.keyCode, modifiers: event.modifierFlags, windowNumber: event.windowNumber)
                    let consumed = MainActor.assumeIsolated { self?.consumes(key) ?? false }
                    return consumed ? nil : event
                }
            } else if !enabled, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private struct KeyPress {
            let code: UInt16
            let modifiers: NSEvent.ModifierFlags
            let windowNumber: Int
        }

        /// Whether this key press is ⌫ on the board window while no text field is being edited, and a card was deleted.
        private func consumes(_ key: KeyPress) -> Bool {
            let deleteKey: UInt16 = 51
            guard key.code == deleteKey, key.modifiers.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty,
                  let window = view?.window, key.windowNumber == window.windowNumber,
                  !(window.firstResponder is NSText) else { return false }
            return delete?() == true
        }
    }
}
