import AppKit
import SwiftUI

struct TranslatorView: View {
    @ObservedObject var model: AppModel
    var onCapture: () -> Void
    var onHotkeyChange: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                if model.showHistory {
                    history.frame(width: 228)
                    Divider()
                }
                VStack(spacing: 0) {
                    directionBar
                    VSplitView {
                        sourcePane.frame(minHeight: 110, idealHeight: 165, maxHeight: 210)
                        resultPane.frame(minHeight: 220)
                    }
                    Divider()
                    footer
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 650, minHeight: 530)
        .sheet(isPresented: $model.showSettings, onDismiss: {
            model.persistSettings()
            onHotkeyChange()
        }) { settings }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "character.bubble.fill")
                .font(.system(size: 25)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("ことば").font(.system(size: 17, weight: .semibold))
                Text("日英翻訳").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("翻訳エンジン", selection: $model.engineKind) {
                ForEach(EngineKind.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .labelsHidden().frame(width: 175).disabled(model.isRunning)
            Button { model.showHistory.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }
                .help("履歴を表示").accessibilityLabel("履歴を表示").buttonStyle(.borderless)
                .padding(.horizontal, 5)
            Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                .help("設定").accessibilityLabel("設定").buttonStyle(.borderless)
        }
        .padding(.horizontal, 26).padding(.vertical, 16)
    }

    private var directionBar: some View {
        HStack {
            Picker("翻訳方向", selection: $model.direction) {
                ForEach(TranslationDirection.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .labelsHidden().frame(width: 170).disabled(model.isRunning)
            Spacer()
            Button(action: onCapture) {
                Label("選択取得の設定", systemImage: "selection.pin.in.out")
            }
            .disabled(model.captureInProgress)
            .help("選択した文章の取得方法と権限を確認します")
            .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28).padding(.vertical, 15)
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("原文").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.source.count)文字").font(.system(size: 11)).foregroundStyle(.tertiary)
                Button {
                    if let text = NSPasteboard.general.string(forType: .string) { model.editSource(text) }
                } label: { Label("貼り付け", systemImage: "doc.on.clipboard") }
                    .font(.system(size: 11)).buttonStyle(.borderless).disabled(model.isRunning)
                Button { model.editSource("") } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("原文を消去").accessibilityLabel("原文を消去")
                    .disabled(model.source.isEmpty)
            }
            ZStack(alignment: .topLeading) {
                if model.source.isEmpty {
                    Text("文章を選んで \(model.shortcut.symbols)\nここに入力・貼り付けもできます")
                        .font(.system(size: 17)).foregroundStyle(.tertiary)
                        .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                }
                TextEditor(text: Binding(get: { model.source }, set: { model.editSource($0) }))
                    .font(.system(size: 16)).lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("翻訳する原文")
            }
        }
        .padding(.horizontal, 30).padding(.top, 8).padding(.bottom, 18)
    }

    private var resultPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("訳文").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                if model.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button {
                    model.fontSize = max(16, model.fontSize - 2)
                    model.persistSettings()
                } label: { Image(systemName: "textformat.size.smaller") }
                    .accessibilityLabel("訳文の文字を小さくする").help("文字を小さくする")
                Text("\(Int(model.fontSize))").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                Button {
                    model.fontSize = min(32, model.fontSize + 2)
                    model.persistSettings()
                } label: { Image(systemName: "textformat.size.larger") }
                    .accessibilityLabel("訳文の文字を大きくする").help("文字を大きくする")
                Divider().frame(height: 15).padding(.horizontal, 4)
                Button { model.copyResult() } label: {
                    Label(model.copied ? "コピーしました" : "コピー", systemImage: model.copied ? "checkmark" : "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!model.isComplete)
            }
            .buttonStyle(.borderless)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.result.isEmpty {
                        Text(model.isRunning ? "訳文ができたところから、ここに表示します。" : "訳文はここに表示されます。")
                            .font(.system(size: 20)).foregroundStyle(.tertiary)
                    } else {
                        Text(model.result)
                            .font(.system(size: model.fontSize)).lineSpacing(8)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(model.isComplete ? "翻訳結果" : "生成途中の訳文")
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.system(size: 13)).foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 30).padding(.top, 24).padding(.bottom, 18)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.captureInProgress ? "選択した文章を取得しています" : model.status)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2)
                if model.isRunning, let start = model.startedAt {
                    TimelineView(.periodic(from: start, by: 0.1)) { context in
                        Text("経過 \(context.date.timeIntervalSince(start), specifier: "%.1f")秒")
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                } else if let complete = model.completeTime {
                    Text("最初の文字 \(model.firstTextTime ?? complete, specifier: "%.1f")秒 · 完了 \(complete, specifier: "%.1f")秒")
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
                } else {
                    Text("選択して \(model.shortcut.symbols)  ·  翻訳 ⌘↩  ·  コピー ⇧⌘C")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if model.isRunning {
                Button("中断する", systemImage: "stop.fill") { model.stop() }
                    .controlSize(.large)
            } else {
                Button { model.translate() } label: {
                    Label("翻訳する", systemImage: "arrow.turn.down.right")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 16)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("翻訳履歴").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.records.count)").font(.caption).foregroundStyle(.secondary)
            }.padding(18)
            if model.records.isEmpty {
                Text(model.saveHistory ? "完了した翻訳をここに保存します。" : "履歴の保存はオフです。設定からオンにできます。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 18)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.records) { record in
                        Button { model.restore(record) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(record.source).lineLimit(3).multilineTextAlignment(.leading)
                                    .font(.system(size: 12)).foregroundStyle(.primary)
                                Text(record.date, style: .time).font(.system(size: 10)).foregroundStyle(.secondary)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { Button("この履歴を削除", role: .destructive) { model.deleteRecord(record.id) } }
                    }
                }.padding(.horizontal, 6)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("設定").font(.title2.weight(.semibold))
            Form {
                Picker("翻訳エンジン", selection: $model.engineKind) {
                    ForEach(EngineKind.allCases) { Text($0.rawValue).tag($0) }
                }
                if model.engineKind == .apple {
                    Text("Apple Intelligenceのオンデバイスモデルを使います。クラウドには送信しません。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let reason = model.engine.availabilityMessage {
                        Text(reason).foregroundStyle(.orange)
                    }
                } else {
                    TextField("ローカルモデル名", text: $model.ollamaModel)
                    Text("Ollamaとモデルの導入が必要です。接続先はこのMac（127.0.0.1）のみです。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("選択した文章を翻訳", selection: $model.shortcut) {
                        ForEach(ShortcutPreset.allCases) { Text($0.label).tag($0) }
                    }
                    if let error = model.hotkeyError { Text(error).foregroundStyle(.orange) }
                    Toggle("選択を取得できないとき、自動コピーで補助する", isOn: $model.copyFallback)
                    Text("呼び出したときだけコピー操作を行い、可能な範囲でクリップボードを復元します。常時監視はしません。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("アクセシビリティ設定を開く") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
                Section {
                    Toggle("翻訳履歴をこのMacに保存する", isOn: $model.saveHistory)
                    Text("初期設定はオフ。オンの場合は直近500件を保存します。オフにしても以前の履歴は残ります。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("保存した履歴をすべて削除", role: .destructive) { model.clearHistory() }
                        .disabled(model.records.isEmpty)
                }
            }.formStyle(.grouped)
            HStack {
                Text("ことば 0.1 · 個人用プレビュー版").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完了") { model.showSettings = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(26).frame(width: 560)
    }
}
