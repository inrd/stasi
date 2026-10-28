import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.isRecording ? "record.circle.fill" : "record.circle")
                .foregroundStyle(model.isRecording ? Color.red : Color.primary)
            if model.isRecording {
                Text(model.elapsedLabel).monospacedDigit()
            }
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            actionButton

            if case .saving(let progress) = model.state {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notice = model.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            folderRow

            if let summary = model.lastSummary, let file = model.lastFile {
                Text("\(file.lastPathComponent) — \(summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
            }

            Divider()
            bottomRow
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 9, height: 9)
            Text(statusText)
                .font(.headline)
                .monospacedDigit()
            Spacer()
        }
    }

    private var actionButton: some View {
        Button {
            model.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                Text(model.isRecording ? "Stop & Save" : "Start Recording")
                Spacer()
                if !model.isRecording {
                    Text("⌘R")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(model.isRecording ? .red : .accentColor)
        .keyboardShortcut("r", modifiers: .command)
        .disabled(model.isSaving || model.isStarting)
    }

    private var folderRow: some View {
        Button {
            model.chooseFolder()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(model.outputFolder?.lastPathComponent ?? "Choose output folder…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isRecording || model.isSaving)
    }

    private var bottomRow: some View {
        HStack(spacing: 14) {
            if model.lastFile != nil {
                Button("Reveal") { model.revealLastFile() }
                    .buttonStyle(.plain)
            }
            Spacer()
            SettingsLink {
                Text("Settings…")
            }
            .buttonStyle(.plain)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
        }
        .font(.callout)
    }

    private var statusText: String {
        switch model.state {
        case .idle:
            return "Ready"
        case .starting:
            return "Starting…"
        case .recording:
            return "Recording \(model.elapsedLabel)"
        case .saving(let progress):
            return "Saving \(Int(progress * 100))%"
        case .failed:
            return "Stopped with an error"
        }
    }

    private var stateColor: Color {
        switch model.state {
        case .idle:
            return .secondary
        case .starting, .saving:
            return .orange
        case .recording:
            return .red
        case .failed:
            return .red
        }
    }
}
