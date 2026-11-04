import AppKit
import ApplicationServices
import Carbon

@MainActor
final class CaptureService {
    var trusted: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func selectedText() -> String? {
        guard trusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.4)
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    func isProtectedInput() -> Bool {
        guard trusted else { return false }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        var subrole: CFTypeRef?
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.4)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == (kAXSecureTextFieldSubrole as String)
    }

    /// Optional fallback, invoked only by the translation hotkey while the source app is frontmost.
    func copySelection() async -> String? {
        guard trusted, !isProtectedInput(), !IsSecureEventInputEnabled() else { return nil }
        let board = NSPasteboard.general
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        var totalBytes = 0
        for item in board.pasteboardItems ?? [] {
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                totalBytes += data.count
                guard totalBytes <= 4_000_000 else { return nil }
                entry[type] = data
            }
            saved.append(entry)
        }
        let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let originalCount = board.changeCount
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return nil }
            if board.changeCount != originalCount {
                let copiedCount = board.changeCount
                let text = board.string(forType: .string)
                // No await between this check and restore: do not overwrite a later clipboard change.
                if board.changeCount == copiedCount {
                    board.clearContents()
                    let items = saved.map { entry -> NSPasteboardItem in
                        let item = NSPasteboardItem()
                        for (type, data) in entry { item.setData(data, forType: type) }
                        return item
                    }
                    board.writeObjects(items)
                }
                return text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil
            }
        }
        return nil
    }
}

@MainActor
final class GlobalHotkey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPressed: (() -> Void)?
    static let keys: [String: UInt32] = ["T": UInt32(kVK_ANSI_T), "R": UInt32(kVK_ANSI_R), "Y": UInt32(kVK_ANSI_Y)]

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in hotkey.onPressed?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(key: String) -> Bool {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        let identifier = EventHotKeyID(signature: 0x4B544241, id: 1)
        return RegisterEventHotKey(Self.keys[key] ?? UInt32(kVK_ANSI_T),
                                   UInt32(controlKey | optionKey), identifier,
                                   GetApplicationEventTarget(), 0, &reference) == noErr
    }
}
