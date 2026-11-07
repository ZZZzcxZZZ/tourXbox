import AppKit
import SwiftUI
#if canImport(MappingCore)
import MappingCore
#endif

struct ShortcutRecorder: NSViewRepresentable {
    var recording: Bool
    var shortcut: Shortcut
    var capture: (Shortcut) -> Void
    var cancel: () -> Void
    func makeNSView(context: Context) -> ShortcutRecordView {
        let view=ShortcutRecordView()
        view.setAccessibilityElement(true); view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("快捷键录制区")
        return view
    }
    func updateNSView(_ view: ShortcutRecordView, context: Context) {
        view.capture=capture; view.cancel=cancel; view.title=recording ? "按下快捷键…" : shortcut.display
        view.recording=recording; view.setAccessibilityValue(view.title)
        if recording,view.window?.firstResponder !== view { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
    }
}
final class ShortcutRecordView: NSButton {
    var recording=false
    var capture: (Shortcut)->Void = {_ in}
    var cancel: ()->Void = {}
    private var modifier: UInt16?
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryPushIn)
        bezelStyle = .rounded
        controlSize = .regular
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        focusRingType = .default
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        guard recording else { return false }; keyDown(with:event); return true
    }
    override func keyDown(with event:NSEvent) {
        guard recording else { super.keyDown(with:event); return }
        if event.keyCode == 53 { recording=false; modifier=nil; cancel(); return }
        let flags=event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers:[UInt16]=[]
        if flags.contains(.control) { modifiers.append(59) }
        if flags.contains(.option) { modifiers.append(58) }
        if flags.contains(.shift) { modifiers.append(56) }
        if flags.contains(.command) { modifiers.append(55) }
        recording=false; modifier=nil; capture(Shortcut(event.keyCode,modifiers))
    }
    override func flagsChanged(with event:NSEvent) {
        guard recording else { return }
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        if !flags.isEmpty, Shortcut.modifierKeys.contains(event.keyCode) { modifier=event.keyCode }
        else if flags.isEmpty, let modifier { self.modifier=nil; recording=false; capture(Shortcut(modifier)) }
    }
    override func resignFirstResponder() -> Bool {
        if recording { recording=false; modifier=nil; DispatchQueue.main.async { self.cancel() } }
        return true
    }
}
