import AppKit
import SwiftUI

struct PlamoSettingsView: View {
    @ObservedObject var installer: PlamoInstaller

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PLaMo 3 Translate 2B")
            Text("このMacだけで翻訳します。原文・訳文を外部に送信しません。")
                .font(.caption).foregroundStyle(.secondary)
            if installer.isInstalling {
                Text(installer.phase).font(.caption)
                if let progress = installer.progress {
                    ProgressView(value: progress)
                    Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("準備を中断", action: installer.cancel)
            } else if installer.isReady {
                Label("準備完了・オフラインで利用できます", systemImage: "checkmark.circle")
                    .font(.caption)
            } else {
                Text("初回に約1.83 GBをダウンロードします。空き容量は3 GB以上を目安にしてください。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("ダウンロードして準備", action: installer.start)
            }
            if let error = installer.error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Link("モデルの利用条件", destination: PlamoInstallation.licenseURL)
                Button("保存先を開く") {
                    let parent = installer.installation.directory.deletingLastPathComponent()
                    try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(parent)
                }
            }.font(.caption)
            Text("Built with PLaMo").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
