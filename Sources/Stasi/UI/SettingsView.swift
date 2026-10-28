import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text(model.outputFolder?.path ?? "Not set")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { model.chooseFolder() }
                    }
                }
            } header: {
                Text("Recordings")
            }

            Section {
                LabeledContent("Format", value: "WAV · 24-bit · device sample rate")
                LabeledContent("Normalization", value: "Peak to −1.0 dBFS")
            } header: {
                Text("Audio")
            }

            Section {
                HStack {
                    Button("Open Log") { NSWorkspace.shared.open(Log.fileURL) }
                    Spacer()
                    Text("v0.1")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 260)
    }
}
