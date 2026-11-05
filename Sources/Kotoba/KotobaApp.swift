import AppKit
import Carbon
import FoundationModels
import SwiftUI

@main
@MainActor
enum KotobaApp {
    static func main() {
        if CommandLine.arguments.contains("--check-model") {
            let engine = TranslationEngine()
            print(engine.availabilityMessage ?? "Apple Intelligence: available")
            return
        }
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--check-hotkey") {
            let hotkey = GlobalHotkey()
            let shortcut = ShortcutPreset.commandJ
            let registered = hotkey.register(shortcut: shortcut)
            print("\(shortcut.label): \(registered ? "registered" : "registration failed")")
            exit(registered ? 0 : 1)
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    let capture = CaptureService()
    let hotkey = GlobalHotkey()
    var window: NSWindow!
    var statusItem: NSStatusItem!
    private var captureTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        let view = TranslatorView(model: model, onCapture: { [weak self] in
            guard let self else { return }
            model.error = "翻訳したいアプリに戻って文章を選択し、\(model.shortcut.label) を押してください。"
            if !capture.trusted { capture.requestPermission() }
        }, onHotkeyChange: { [weak self] in self?.registerHotkey() })
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 730),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "ことば"
        window.minSize = NSSize(width: 650, height: 560)
        window.isReleasedWhenClosed = false
        // Bring the window to the caller's Space instead of activating its previous desktop.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.contentView = NSHostingView(rootView: view)
        window.setFrameAutosaveName("KotobaMainWindow")
        window.center()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        let preview = CommandLine.arguments.contains("--preview")
        let smokePlamo = CommandLine.arguments.contains("--smoke-test-plamo")
        if preview {
            model.loadPreview()
        } else if !smokePlamo {
            registerHotkey()
        }
        if smokePlamo {
            model.previewMode = true // Smoke runs must not change saved preferences or history.
            model.engineKind = .plamo
        }
        showWindow()
        if !preview, model.engineKind == .apple { model.engine.prewarm() }
        if CommandLine.arguments.contains("--smoke-test") || smokePlamo {
            model.editSource("Please do not share this document until Friday. The budget is 250 dollars.")
            model.direction = .toJapanese
            model.translate()
            Task { [weak self] in
                guard let self else { return }
                while model.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
                let report: [String: Any] = [
                    "complete": model.isComplete, "source": model.source, "result": model.result,
                    "engine": model.engineKind.rawValue,
                    "error": model.error ?? "", "firstTextSeconds": model.firstTextTime ?? -1,
                    "completeSeconds": model.completeTime ?? -1,
                    "hotkey": model.shortcut.label, "hotkeyError": model.hotkeyError ?? ""
                ]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                    let args = CommandLine.arguments
                    if let index = args.firstIndex(of: "--report"), args.indices.contains(index + 1) {
                        try? data.write(to: URL(fileURLWithPath: args[index + 1]))
                    }
                }
                try? await Task.sleep(for: .milliseconds(400))
                writeSnapshot()
                NSApp.terminate(nil)
            }
        } else if CommandLine.arguments.contains("--snapshot") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.writeSnapshot()
                if CommandLine.arguments.contains("--exit-after-snapshot") { NSApp.terminate(nil) }
            }
        }
    }

    func registerHotkey() {
        model.hotkeyError = hotkey.register(shortcut: model.shortcut) ? nil : "このキーは登録できませんでした。以前の翻訳ショートカットを解除するか、設定で別のキーを選んでください。"
        if let error = model.hotkeyError { model.error = error }
        hotkey.onPressed = { [weak self] in self?.captureAndTranslate() }
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        model.plamoInstaller.cancel()
        model.engine.shutdown()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.stop()
        sender.orderOut(nil)
        return false
    }

    @objc func openTranslator() { showWindow() }
    @objc func openSettings() { showWindow(); model.showSettings = true }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func translateClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            showWindow()
            model.error = "クリップボードに文章がありません。"
            return
        }
        showWindow()
        model.useSelection(text)
    }

    @objc func translateSelection(_ pasteboard: NSPasteboard, userData: String?,
                                  error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        showWindow()
        model.useSelection(text)
    }

    func captureAndTranslate() {
        guard !model.captureInProgress else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            showWindow()
            model.translate()
            return
        }
        model.stop()
        model.showSettings = false
        if !capture.trusted {
            showWindow()
            model.error = "他のアプリの選択文章を取得するには、アクセシビリティで「ことば」を許可してください。手入力・貼り付け・サービス経由の翻訳は許可なしでも使えます。"
            capture.requestPermission()
            return
        }
        guard !capture.isProtectedInput(), !IsSecureEventInputEnabled() else {
            showWindow()
            model.error = "保護された入力欄は取得しません。"
            return
        }
        if let text = capture.selectedText() {
            showWindow()
            model.useSelection(text)
            return
        }
        guard model.copyFallback else {
            showWindow()
            model.error = "このアプリから選択文章を直接取得できませんでした。設定の「自動コピーで補助」を有効にするか、サービスメニューの「ことばで翻訳」をお使いください。"
            return
        }
        model.captureInProgress = true
        captureTask = Task { [weak self] in
            guard let self else { return }
            let text = await capture.copySelection()
            model.captureInProgress = false
            showWindow()
            if let text { model.useSelection(text) }
            else { model.error = "選択文章を取得できませんでした。文章を選び直すか、貼り付けて翻訳してください。" }
        }
    }

    private func buildMenus() {
        let menuBar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "ことばを表示", action: #selector(openTranslator), keyEquivalent: "0")
        appMenu.addItem(withTitle: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "サービス", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "サービス")
        appMenu.addItem(services)
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "ことばを終了", action: #selector(quit), keyEquivalent: "q")
        appItem.submenu = appMenu
        menuBar.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "編集")
        edit.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "切り取り", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menuBar.addItem(editItem)
        NSApp.mainMenu = menuBar
        for item in appMenu.items where item.action != nil { item.target = self }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "ことば・日英翻訳")
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: "翻訳を開く", action: #selector(openTranslator), keyEquivalent: "")
        statusMenu.addItem(withTitle: "クリップボードを翻訳", action: #selector(translateClipboard), keyEquivalent: "")
        statusMenu.addItem(withTitle: "設定…", action: #selector(openSettings), keyEquivalent: "")
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "終了", action: #selector(quit), keyEquivalent: "")
        for item in statusMenu.items { item.target = self }
        statusItem.menu = statusMenu
    }

    private func writeSnapshot() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), args.indices.contains(index + 1),
              let content = window.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        do { try data.write(to: URL(fileURLWithPath: args[index + 1])) }
        catch { print("Snapshot error: \(error.localizedDescription)") }
    }
}
