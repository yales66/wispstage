import SwiftUI

/// The settings window (⌘,).
struct SettingsView: View {
    @AppStorage(SettingsKey.showCompleted) private var showCompleted = true
    @AppStorage(SettingsKey.remind) private var remind = true
    @AppStorage(SettingsKey.density) private var density = CardDensity.comfortable

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showCompleted) {
                    Text(L("Show completed cards")).accessibilityIdentifier("settings.showCompleted.label")
                }
                .accessibilityIdentifier("settings.showCompleted")
                Picker(selection: $density) {
                    ForEach(CardDensity.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text(L("Card density")).accessibilityIdentifier("settings.density.label")
                }
                .accessibilityIdentifier("settings.density")
            } header: {
                Text(L("Board")).accessibilityIdentifier("settings.boardHeader")
            }
            Section {
                Toggle(isOn: $remind) {
                    remindLabel
                }
                .accessibilityIdentifier("settings.remind")
            } header: {
                Text(L("Notifications")).accessibilityIdentifier("settings.notificationsHeader")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(L("Settings"))
    }

    @ViewBuilder
    private var remindLabel: some View {
        if PlantedBugs.narrowRemindLabel {
            Text(L("Remind me when a card is due"))
                .lineLimit(1)
                .frame(width: PlantedBugs.remindLabelWidth, alignment: .leading)
                .accessibilityIdentifier("settings.remind.label")
        } else {
            Text(L("Remind me when a card is due"))
                .accessibilityIdentifier("settings.remind.label")
        }
    }
}
