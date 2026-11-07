import AppKit
import ApplicationServices
#if canImport(MappingCore)
import MappingCore
#endif

@MainActor final class EventOutput {
    private(set) var ledger = HoldLedger()
    private let source = CGEventSource(stateID: .privateState)
    var log: (String) -> Void = { _ in }
    var dryRun = false
    var probePID: pid_t?
    var canSend: () -> Bool = { false }
    private var pointerTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?
    private(set) var modifierFlags=CGEventFlags()
    private func updateModifierFlags(){
        let next=ledger.owners.keys.reduce(CGEventFlags()){$0.union(Self.flag($1))}
        guard next != modifierFlags else{return}
        modifierFlags=next
        // Keep the tap enabled: explicitly disabling it can feed back user-input disable notifications.
        // The callback returns immediately while cached flags are empty.
    }
    static func flag(_ key: UInt16) -> CGEventFlags {
        switch key {
        case 58: return [.maskAlternate, CGEventFlags(rawValue: 0x20)]
        case 61: return [.maskAlternate, CGEventFlags(rawValue: 0x40)]
        case 55: return [.maskCommand, CGEventFlags(rawValue: 0x08)]
        case 54: return [.maskCommand, CGEventFlags(rawValue: 0x10)]
        case 56: return [.maskShift, CGEventFlags(rawValue: 0x02)]
        case 60: return [.maskShift, CGEventFlags(rawValue: 0x04)]
        case 59: return [.maskControl, CGEventFlags(rawValue: 0x01)]
        case 62: return [.maskControl, CGEventFlags(rawValue: 0x2000)]
        default: return []
        }
    }
    @discardableResult private func emit(_ key: UInt16, down: Bool) -> Bool {
        if dryRun { log("模拟 \(Shortcut(key).display) \(down ? "↓" : "↑")"); return true }
        // Releases remain attempted even after focus changes.
        if down && !canSend() { return false }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else {
            log("无法创建键盘事件"); return false
        }
        var flags = CGEventSource.flagsState(.hidSystemState)
        // HID state can still contain our last synthetic modifier-down. A release
        // must clear that bit before applying the remaining owners' held flags.
        if !down {flags.subtract(Self.flag(key))}
        flags.formUnion(modifierFlags)
        if !Self.flag(key).isEmpty { event.type = .flagsChanged }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: 0x4252555348)
        if let probePID { event.postToPid(probePID) }
        else { event.post(tap: .cghidEventTap) }
        log("投递 \(Shortcut(key).display) \(down ? "↓" : "↑")")
        return true
    }
    private func key(_ key: UInt16, owner: String, down: Bool) {
        if down && !dryRun && !canSend() { return }
        guard ledger.set(key, owner: owner, down: down) else { return }
        updateModifierFlags()
        if !emit(key, down: down),down {
            _=ledger.set(key,owner:owner,down:false);updateModifierFlags()
        }
    }
    func apply(_ binding: MappingBinding, down: Bool) {
        let owner = binding.id
        switch binding.mode {
        case .hold:
            for k in down ? binding.shortcut.keys : Array(binding.shortcut.keys.reversed()) { key(k, owner: owner, down: down) }
        case .tap:
            guard down else { return }
            // Balanced modifier transitions; another owner holding the same key retains it.
            for k in binding.shortcut.keys { key(k, owner: owner, down: true) }
            for k in binding.shortcut.keys.reversed() { key(k, owner: owner, down: false) }
        case .disabled, .stop, .palette: break
        }
    }
    func setPaletteSampling(_ down: Bool) { key(58, owner: "dynamic-palette", down: down) }
    func releaseAll() {
        // Ordinary keys first, then modifiers, preserving aggregate flags at each edge.
        let keys = ledger.owners.keys.sorted { (Self.flag($0).isEmpty ? 0 : 1) < (Self.flag($1).isEmpty ? 0 : 1) }
        for k in keys {
            for owner in Array(ledger.owners[k] ?? []) { key(k, owner: owner, down: false) }
        }
    }
    func setPointerBridge(_ enabled: Bool) -> Bool {
        if !enabled {
            if let pointerTap { CFMachPortInvalidate(pointerTap) }
            if let tapRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(),tapRunLoopSource,.commonModes) }
            pointerTap=nil; tapRunLoopSource=nil; return false
        }
        if pointerTap != nil { return true }
        let types: [CGEventType] = [.mouseMoved,.leftMouseDown,.leftMouseUp,.leftMouseDragged,.rightMouseDown,.rightMouseUp,.rightMouseDragged,.otherMouseDown,.otherMouseUp,.otherMouseDragged,.tabletPointer,.tabletProximity,.scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let output = Unmanaged<EventOutput>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    output.releaseAll()
                    output.log("笔事件兼容桥已停用，已释放本程序按键")
                    if let tap = output.pointerTap { CGEvent.tapEnable(tap:tap,enable:true) }
                    return Unmanaged.passUnretained(event)
                }
                guard !output.modifierFlags.isEmpty else{return Unmanaged.passUnretained(event)}
                if !output.dryRun && output.canSend() && event.getIntegerValueField(.eventSourceUserData) != 0x4252555348 {
                    // Amend the original event; pressure, tilt and tablet fields are preserved.
                    event.flags.formUnion(output.modifierFlags)
                }
                return Unmanaged.passUnretained(event)
            }
        }
        guard let tap = CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,options:.defaultTap,eventsOfInterest:mask,callback:callback,userInfo:Unmanaged.passUnretained(self).toOpaque()) else { return false }
        pointerTap=tap
        tapRunLoopSource=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0)
        if let tapRunLoopSource { CFRunLoopAddSource(CFRunLoopGetMain(),tapRunLoopSource,.commonModes) }
        CGEvent.tapEnable(tap:tap,enable:true)
        return true
    }
}

extension Shortcut {
    private static let keyDisplayNames: [UInt16:String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"Return",37:"L",38:"J",39:"′",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"Tab",49:"Space",50:"`",51:"Delete",53:"Esc",54:"Right ⌘",55:"⌘",56:"⇧",58:"⌥",59:"⌃",60:"Right ⇧",61:"Right ⌥",62:"Right ⌃",65:"Keypad .",67:"Keypad *",69:"Keypad +",71:"Clear",75:"Keypad /",76:"Keypad Enter",78:"Keypad −",79:"F18",81:"Keypad =",82:"Keypad 0",83:"Keypad 1",84:"Keypad 2",85:"Keypad 3",86:"Keypad 4",87:"Keypad 5",88:"Keypad 6",89:"Keypad 7",91:"Keypad 8",92:"Keypad 9",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",109:"F10",111:"F12",114:"Help",115:"Home",116:"Page ↑",117:"Forward Delete",118:"F4",119:"End",120:"F2",121:"Page ↓",122:"F1",123:"←",124:"→",125:"↓",126:"↑"]
    var display: String {
        return modifiers.map { Self.keyDisplayNames[$0] ?? "\($0)" }.joined() + (Self.keyDisplayNames[key] ?? "Key \(key)")
    }
}
