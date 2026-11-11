import AppKit
import SwiftUI
import GameController
import ApplicationServices
import Security
import Carbon
#if DEBUG
import Combine
#endif
#if canImport(MappingCore)
import MappingCore
#endif

@MainActor final class ControllerModel: ObservableObject {
    let lifecycle=AppLifecyclePreferences()
    @Published var settingsPresented=false
    @Published private(set) var followInput=UserDefaults.standard.object(forKey:"controller.followInput") as? Bool ?? true
    @Published var settingsSection:SettingsSection = .general
    weak var workspaceWindow:NSWindow?
    @Published var profile = Profile.drawing {didSet{profileEncodingSupported=profile.supportsEncoding(.macOSVirtualKey)}}
    private var profileEncodingSupported=true
    @Published var armed = false
    @Published var dryRun = false
    @Published var recording = false
    @Published var selected: PadControl = .lt {didSet{if oldValue != selected {selectedBindingID=nil}}}
    @Published var selectedBindingID:String?
    @Published var page = "mapping"
    @Published var providedControls: Set<PadControl> = []
    @Published private(set) var inputGlyphs:[PadControl:String]=[:]
    @Published var controllerConnected = false
    @Published var controllerName = "等待连接"
    @Published var frontApp = ""
    @Published var trusted = false
    @Published var postAllowed = false
    @Published var bridgeActive = false
    @Published var signatureValid = true
    @Published var pressed: Set<PadControl> = []
    let palette=DynamicPaletteCoordinator()
    @Published var logs: [String] = []
    @Published var status = "已暂停"
    @Published var errorMessage: String?
    @Published var confirmReset = false
    @Published var probeToken = 0
    @Published var probeResult = "尚未测试"
    @Published var appChoices: [(String,String)] = []
    private let output = EventOutput()
    private var controller: GCController?
    private var gate = InputGate()
    private var gestureRouter=GestureRouter()
    private var axes: [PadControl:Hysteresis] = [:]
    private var stableButtons:[PadControl:StableButton]=[:]
    private var releaseCheck:DispatchWorkItem?
    private var maxLeftRadius:Float=0
    private var timer: Timer?
    #if DEBUG
    private var debugTrace:AnyCancellable?
    #endif
    private var observers: [NSObjectProtocol] = []
    private var suspended = false
    private var lastAllowed = false
    private var frontPID: pid_t?
    private var lastHealthCheck = 0.0
    private var lastSignatureCheck = 0.0
    private var frontBundleID: String?
    private var systemGestureActive: Bool?
    private var lastDiagnostics: Data?
    private var bridgeRequested: Bool?
    private let persistenceQueue=DispatchQueue(label:"BrushPad.persistence",qos:.utility)
    private var pendingSave: DispatchWorkItem?
    private var activeBindings: [String:MappingBinding] = [:]
    private var probing = false
    private let ownID = Bundle.main.bundleIdentifier ?? "local.BrushPad.prototype"
    private let settingsURL: URL
    var canPost: Bool { trusted || postAllowed }
    var selectedBindings:[MappingBinding] {profile.bindings.filter{$0.control == selected}}
    var currentBinding: MappingBinding {selectedBindings.first{$0.id == selectedBindingID} ?? selectedBindings.first ?? MappingBinding(selected,.disabled)}
    func selectBinding(_ id:String){guard id != currentBinding.id else{return};setRecording(false);selectedBindingID=id}
    func addBinding(_ gesture:InputGesture,companion:PadControl?=nil){
        var b=MappingBinding(selected,.disabled);b.gesture=gesture;b.companions=companion.map{[$0]} ?? []
        if let existing=selectedBindings.first(where:{$0.id == b.id}) {selectBinding(existing.id);return}
        release("添加功能");profile.bindings.append(b);selectedBindingID=b.id;save()
    }
    func removeCurrentBinding(){
        let b=currentBinding
        guard selectedBindings.count>1 else{setMode(.disabled);return}
        release("移除功能");profile.bindings.removeAll{$0.id == b.id};selectedBindingID=nil;save();refresh()
    }
    var diagnosticSummary: String {
        "版本 0.22.1 · PID \(ProcessInfo.processInfo.processIdentifier)\n路径：\(Bundle.main.bundleURL.path)\n签名有效：\(signatureValid)\nAX：\(trusted) · PostEvent：\(postAllowed)\n\(probeResult)\n\n" + logs.joined(separator:"\n")
    }
    init() {
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
            .appendingPathComponent("BrushPad",isDirectory:true)
        settingsURL = support.appendingPathComponent("settings-palette.json")
        do {
            let legacy=support.appendingPathComponent("settings.json")
            let readURL=FileManager.default.fileExists(atPath:settingsURL.path) ? settingsURL:legacy
            if FileManager.default.fileExists(atPath:readURL.path) {
                let saved = try JSONDecoder().decode(Profile.self,from:Data(contentsOf:readURL))
                profile = try saved.upgraded()
            }
        } catch { errorMessage="读取配置失败，已使用默认映射：\(error.localizedDescription)" }
        palette.openSettings = { [weak self] in self?.showSettings(.palette) }
        palette.sampling = { [weak self] down in self?.output.setPaletteSampling(down) }
        output.log = { [weak self] in self?.record($0) }
        output.canSend = { [weak self] in
            guard let self else { return false }
            if self.probing { return self.output.probePID == ProcessInfo.processInfo.processIdentifier }
            return self.allowed()
        }
        GCController.shouldMonitorBackgroundEvents = true
        let nc = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(nc.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.attach() }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.suspended=true; self?.stop("系统会话暂停") }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.suspended=false; self?.stop("系统恢复，映射保持暂停") }
            })
        }
        observers.append(workspace.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(nc.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop("退出"); self?.flushSave(); _ = self?.output.setPointerBridge(false) }
        })
        save(); updateAppChoices(); attach(); refresh()
        let healthTimer=Timer(timeInterval:1.0,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        healthTimer.tolerance=0.2
        timer=healthTimer;RunLoop.main.add(healthTimer,forMode:.common)
        record("已载入配置 · 默认全局范围，编辑窗口内暂停输出")
        #if DEBUG
        debugTrace=RuntimeTrace.observe(objectWillChange,name:"ControllerModel")
        #endif
    }
    func record(_ text: String) {
        let line="\(Date().formatted(date:.omitted,time:.standard))  \(text)"
        logs=Array(([line]+logs).prefix(80))
    }
    private func release(_ reason: String,preservingPreview:Bool=false) {
        if !preservingPreview || !palette.isPreview {palette.cancel()}
        let hadKeys = !activeBindings.isEmpty || !output.ledger.owners.isEmpty
        output.releaseAll(); activeBindings.removeAll(); gate.suspend(); lastAllowed=false
        gestureRouter.suspend(held:pressed)
        if hadKeys { record("已释放：\(reason)") }
    }
    func stop(_ reason: String = "手动停止") { release(reason); publish(\.armed,false); configureSystemGestures(active: false); publish(\.bridgeActive,output.setPointerBridge(false)); bridgeRequested=false; refreshStatus() }
    func toggleRunning() {
        if armed { stop(); return }
        refresh()
        guard profile.supportsEncoding(.macOSVirtualKey) else {errorMessage="此配置使用其他平台的键码，需要先转换为 macOS 快捷键。";return}
        guard signatureValid else { errorMessage="当前应用文件已被替换。请退出后重新打开这份固定构建。"; return }
        if !canPost && !dryRun && !profile.bindings.contains(where:{$0.mode == .palette}) {
            page="permissions"
            requestPermission()
            return
        }
        release("开始映射"); armed=true; refresh()
    }
    func showMainWindow(){NSApp.setActivationPolicy(.regular);workspaceWindow?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    func showSettings(_ section:SettingsSection){
        release("打开设置")
        settingsSection=section;settingsPresented=true;showMainWindow()
    }
    func requestPermission() {
        // Ask the system to authorize this executable, rather than trusting another copy's switch.
        _ = CGRequestPostEventAccess()
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
        refresh()
    }
    func openPermissionSettings() {
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    func updateAppChoices() {
        var result = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != ownID }
            .compactMap { app -> (String,String)? in guard let id=app.bundleIdentifier else { return nil }; return (app.localizedName ?? id,id) }
        if !result.contains(where: {$0.1 == "com.adobe.Photoshop"}) { result.append(("Photoshop","com.adobe.Photoshop")) }
        if !result.contains(where: {$0.1 == profile.targetBundleID}) { result.append((profile.targetBundleID,profile.targetBundleID)) }
        appChoices=result.sorted{$0.0.localizedCompare($1.0) == .orderedAscending}
    }
    func setScope(_ scope: MappingScope) { release("改变范围"); profile.scope=scope; save(); refresh() }
    func setTarget(_ id: String) { release("改变目标应用"); profile.targetBundleID=id; save(); refresh() }
    func setMode(_ mode: ActionMode) { var b=currentBinding; b.mode=mode; update(b) }
    func setLabel(_ label: String) { var b=currentBinding; b.label=String(label.prefix(80)); update(b) }
    func setShortcut(_ shortcut: Shortcut) {
        var b=currentBinding; b.shortcut=shortcut
        if b.mode == .disabled || b.mode == .stop { b.mode = .hold }
        update(b)
    }
    func update(_ b: MappingBinding) {
        let previous=currentBinding.id
        guard !profile.bindings.contains(where:{$0.id == b.id && $0.id != previous}) else {
            errorMessage="此按键的相同手势与组合已配置。请编辑已有功能，或选择其他手势／组合。";return
        }
        release("编辑映射")
        if let i=profile.bindings.firstIndex(where:{$0.id == previous}) {profile.bindings[i]=b}
        selectedBindingID=b.id
        systemGestureActive=nil;save();refresh()
    }
    func setDryRun(_ value: Bool) { release("切换预览"); dryRun=value; output.dryRun=value; refresh() }
    func setBridge(_ enabled: Bool) { release("兼容设置变化"); profile.bridgePointerFlags=enabled; save(); refresh() }
    func setFollowInput(_ enabled:Bool){
        guard followInput != enabled else{return}
        followInput=enabled;UserDefaults.standard.set(enabled,forKey:"controller.followInput")
    }
    func setRecording(_ enabled: Bool) { guard recording != enabled else { return }; release("录制快捷键"); recording=enabled; refresh() }
    func resetProfile() { release("恢复默认"); profile = .drawing; systemGestureActive=nil; save(); updateAppChoices(); refresh() }
    func setGesture(_ gesture:InputGesture) {var b=currentBinding;b.gesture=gesture;update(b)}
    var paletteBinding:MappingBinding {profile.bindings.first{$0.mode == .palette} ?? MappingBinding(.lt,.palette,Shortcut(58),"动态调色盘")}
    func setPaletteInvoker(control:PadControl?=nil,gesture:InputGesture?=nil) {
        var b=paletteBinding
        selected=b.control;selectedBindingID=b.id
        if let control {b.control=control;b.companions=[]}
        if let gesture {b.gesture=gesture}
        update(b);selected=b.control;selectedBindingID=b.id
        if b.gesture == .doubleHold {palette.model.preferences.holdToShow=true;palette.model.save()}
    }
    func setCompanion(_ control:PadControl,enabled:Bool) {
        var b=currentBinding
        if enabled,!b.companions.contains(control),b.companions.count<3 {b.companions.append(control)}
        if !enabled {b.companions.removeAll{$0==control}}
        update(b)
    }
    private func save() {
        profileEncodingSupported=profile.supportsEncoding(.macOSVirtualKey)
        do {
            try profile.validate()
            let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            let data=try encoder.encode(profile), url=settingsURL
            pendingSave?.cancel()
            let task=DispatchWorkItem { [weak self] in
                do {
                    try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
                    try data.write(to:url,options:.atomic)
                } catch {
                    let message=error.localizedDescription
                    Task { @MainActor in self?.errorMessage="保存失败：\(message)" }
                }
            }
            pendingSave=task; persistenceQueue.asyncAfter(deadline:.now()+0.25,execute:task)
        } catch { errorMessage="保存失败：\(error.localizedDescription)" }
    }
    private func flushSave() {
        pendingSave?.cancel()
        let snapshot=profile, url=settingsURL
        persistenceQueue.sync {
            if let data=try? JSONEncoder().encode(snapshot) { try? data.write(to:url,options:.atomic) }
        }
    }
    private func publish<T: Equatable>(_ key: ReferenceWritableKeyPath<ControllerModel,T>,_ value: T) {
        if self[keyPath:key] != value { self[keyPath:key]=value }
    }
    func exportProfile() {
        let panel=NSSavePanel(); panel.nameFieldStringValue="tourXbox-mapping.json"; panel.allowedContentTypes=[.json]
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do { let e=JSONEncoder(); e.outputFormatting=[.prettyPrinted,.sortedKeys]; try e.encode(profile).write(to:url,options:.atomic) }
        catch { errorMessage=error.localizedDescription }
    }
    func importProfile() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.json]; panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK, let url=panel.url else { return }
        do {
            let data=try Data(contentsOf:url)
            guard data.count < 100_000 else { throw ProfileError.invalid("配置文件过大") }
            let value=try JSONDecoder().decode(Profile.self,from:data).upgraded()
            release("导入配置"); profile=value; systemGestureActive=nil; save(); updateAppChoices(); refresh()
        } catch { errorMessage="无法导入：\(error.localizedDescription)" }
    }
    private func attach() {
        let available=GCController.controllers().filter{$0.extendedGamepad != nil}
        if controller === available.first { return }
        configureSystemGestures(active:false)
        systemGestureActive=nil
        controller?.extendedGamepad?.valueChangedHandler=nil
        release("设备变化"); axes.removeAll();stableButtons.removeAll();releaseCheck?.cancel();releaseCheck=nil; controller=available.first
        publish(\.controllerName,controller?.vendorName ?? "等待连接")
        publish(\.controllerConnected,controller != nil)
        providedControls = []; inputGlyphs=[:]
        guard let controller,let pad=controller.extendedGamepad else { pressed=[]; return }
        providedControls = Set(PadControl.allCases).subtracting(PadControl.addedControls)
        if pad.leftThumbstickButton == nil { providedControls.remove(.l3) }
        if pad.rightThumbstickButton == nil { providedControls.remove(.r3) }
        if pad.buttonOptions == nil { providedControls.remove(.view) }
        providedControls.formUnion([.rightStickLeft,.rightStickRight,.rightStickUp,.rightStickDown])
        if pad.buttonHome != nil { providedControls.insert(.home) }
        if let xbox = pad as? GCXboxGamepad {
            if xbox.buttonShare != nil { providedControls.insert(.share) }
            for (control, button) in [(PadControl.paddle1,xbox.paddleButton1),(.paddle2,xbox.paddleButton2),(.paddle3,xbox.paddleButton3),(.paddle4,xbox.paddleButton4)] where button != nil { providedControls.insert(control) }
        }
        let glyphElements:[(PadControl,GCControllerElement?)]=[
            (.a,pad.buttonA),(.b,pad.buttonB),(.x,pad.buttonX),(.y,pad.buttonY),
            (.lt,pad.leftTrigger),(.rt,pad.rightTrigger),(.lb,pad.leftShoulder),(.rb,pad.rightShoulder),
            (.l3,pad.leftThumbstickButton),(.r3,pad.rightThumbstickButton),
            (.view,pad.buttonOptions),(.menu,pad.buttonMenu),(.home,pad.buttonHome),(.share,(pad as? GCXboxGamepad)?.buttonShare)]
        inputGlyphs=Dictionary(uniqueKeysWithValues:glyphElements.compactMap { control,element in
            guard let name=element?.unmappedSfSymbolsName else {return nil}
            return (control,name)
        })
        controller.handlerQueue = .main
        pad.valueChangedHandler = { [weak self] _,_ in MainActor.assumeIsolated { self?.sample() } }
        record("已连接 \(controllerName)"); sample()
    }
    func availability(_ control: PadControl) -> String {
        !controllerConnected ? "等待设备检测" : providedControls.contains(control) ? "设备已提供" : "当前设备未提供"
    }
    private func configureSystemGestures(active: Bool) {
        guard systemGestureActive != active, let pad = controller?.extendedGamepad else { return }
        systemGestureActive=active
        let buttons: [(PadControl, GCControllerButtonInput?)] = [(.menu,pad.buttonMenu),(.view,pad.buttonOptions),(.home,pad.buttonHome),(.share,(pad as? GCXboxGamepad)?.buttonShare)]
        for (control,button) in buttons {
            let mapped = profile.bindings.contains { $0.control == control && $0.mode != .disabled }
            button?.preferredSystemGestureState = active && mapped ? .disabled : .enabled
        }
    }
    private func allowed() -> Bool {
        armed && !recording && !probing && !suspended && signatureValid && profileEncodingSupported && !IsSecureEventInputEnabled()
        && (dryRun || canPost) && profile.allows(frontBundleID:frontBundleID,ownBundleID:ownID)
    }
    private func paletteAllowed()->Bool {
        armed && !recording && !probing && !suspended && signatureValid && !IsSecureEventInputEnabled()
        && profile.allows(frontBundleID:frontBundleID,ownBundleID:ownID)
    }
    func refresh() {
        let wasPost=canPost
        publish(\.trusted,AXIsProcessTrusted()); publish(\.postAllowed,CGPreflightPostEventAccess())
        if wasPost && !canPost { release("当前进程的事件许可失效") }
        let app=NSWorkspace.shared.frontmostApplication
        publish(\.frontApp,app?.localizedName ?? "未知应用")
        frontBundleID=app?.bundleIdentifier
        if frontPID != app?.processIdentifier { release("切换前台应用",preservingPreview:app?.bundleIdentifier == ownID); frontPID=app?.processIdentifier }
        let now=ProcessInfo.processInfo.systemUptime
        if now-lastSignatureCheck >= 30 {
            lastSignatureCheck=now
            DispatchQueue.global(qos:.utility).async { [weak self] in
                var code:SecCode?
                let valid=SecCodeCopySelf([],&code) == errSecSuccess && code.map { SecCodeCheckValidity($0,[],nil) == errSecSuccess } == true
                Task { @MainActor in
                    guard let self else { return }
                    self.publish(\.signatureValid,valid)
                    if !valid { self.release("签名检查失效") }
                    self.refreshStatus()
                }
            }
        }
        if now-lastHealthCheck >= 10 {
            lastHealthCheck=now; attach()
        }
        let bridgeWanted=profile.bridgePointerFlags && armed && !dryRun && canPost && signatureValid
        if bridgeRequested != bridgeWanted {
            bridgeRequested=bridgeWanted
            publish(\.bridgeActive,output.setPointerBridge(bridgeWanted))
        }
        let can=allowed()
        if lastAllowed && !can { release("输出条件变化",preservingPreview:frontBundleID == ownID) }
        lastAllowed=can; configureSystemGestures(active:can); refreshStatus(); sample(); writeDiagnostics()
    }
    private func refreshStatus() {
        let next: String
        if !signatureValid { next="应用文件发生变化，需要重启" }
        else if !dryRun && !canPost { next=armed && profile.bindings.contains(where:{$0.mode == .palette}) ? "调色盘已启用 · 快捷键等待系统确认":"当前构建的发送许可尚未确认" }
        else if controller == nil { next="等待手柄连接" }
        else if !armed { next="已暂停" }
        else if recording { next="录制快捷键时暂停" }
        else if suspended || IsSecureEventInputEnabled() { next="系统受保护输入，已暂停" }
        else if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ownID { next="编辑界面内暂停 · 切到其他应用即生效" }
        else if !profile.allows(frontBundleID:frontBundleID,ownBundleID:ownID) { next="等待指定应用" }
        else { next = dryRun ? "预览中 · 不发送按键" : "映射已启用" }
        publish(\.status,next)
    }
    private func state(_ control:PadControl,_ value:Float) -> Bool {
        var h=axes[control] ?? Hysteresis(); let down=h.update(value); axes[control]=h; return down
    }
    private func sample() {
        guard !probing, let pad=controller?.extendedGamepad else { if controller == nil && !pressed.isEmpty { pressed=[] }; return }
        let xbox = pad as? GCXboxGamepad
        let rawValues: [(PadControl,Bool)] = [(.lt,state(.lt,pad.leftTrigger.value)),(.rt,state(.rt,pad.rightTrigger.value)),
            (.lb,pad.leftShoulder.isPressed),(.rb,pad.rightShoulder.isPressed),(.l3,pad.leftThumbstickButton?.isPressed ?? false),(.r3,pad.rightThumbstickButton?.isPressed ?? false),
            (.home,pad.buttonHome?.isPressed ?? false),(.share,xbox?.buttonShare?.isPressed ?? false),
            (.paddle1,xbox?.paddleButton1?.isPressed ?? false),(.paddle2,xbox?.paddleButton2?.isPressed ?? false),
            (.paddle3,xbox?.paddleButton3?.isPressed ?? false),(.paddle4,xbox?.paddleButton4?.isPressed ?? false),
            (.view,pad.buttonOptions?.isPressed ?? false),(.menu,pad.buttonMenu.isPressed),
            (.a,pad.buttonA.isPressed),(.b,pad.buttonB.isPressed),(.x,pad.buttonX.isPressed),(.y,pad.buttonY.isPressed),
            (.left,pad.dpad.left.isPressed),(.right,pad.dpad.right.isPressed),(.up,pad.dpad.up.isPressed),(.down,pad.dpad.down.isPressed),
            (.stickLeft,state(.stickLeft,-pad.leftThumbstick.xAxis.value)),(.stickRight,state(.stickRight,pad.leftThumbstick.xAxis.value)),
            (.stickUp,state(.stickUp,pad.leftThumbstick.yAxis.value)),(.stickDown,state(.stickDown,-pad.leftThumbstick.yAxis.value)),
            (.rightStickLeft,state(.rightStickLeft,-pad.rightThumbstick.xAxis.value)),(.rightStickRight,state(.rightStickRight,pad.rightThumbstick.xAxis.value)),
            (.rightStickUp,state(.rightStickUp,pad.rightThumbstick.yAxis.value)),(.rightStickDown,state(.rightStickDown,-pad.rightThumbstick.yAxis.value))]
        let now=ProcessInfo.processInfo.systemUptime
        maxLeftRadius=max(maxLeftRadius,hypot(pad.leftThumbstick.xAxis.value,pad.leftThumbstick.yAxis.value))
        let values=rawValues.map { control,raw -> (PadControl,Bool) in
            var button=stableButtons[control] ?? StableButton()
            let down=button.update(raw,time:now);stableButtons[control]=button
            return(control,down)
        }
        if releaseCheck==nil,stableButtons.values.contains(where:{$0.pendingRelease != nil}) {
            let work=DispatchWorkItem{[weak self] in self?.releaseCheck=nil;self?.sample()}
            releaseCheck=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.04,execute:work)
        }
        publish(\.pressed,Set(values.filter{$0.1}.map{$0.0}))
        // The unmodified emergency stop remains available while configuring.
        if armed,rawValues.contains(where:{item in item.1 && profile.bindings.contains(where:{$0.control == item.0 && $0.mode == .stop && $0.gesture == .press && $0.companions.isEmpty}) && profile.bindings.filter{$0.control == item.0 && $0.mode != .disabled}.count == 1}) {
            stop("手柄停止键");return
        }
        let canSend=allowed()
        let routed=gestureRouter.updateBindings(bindings:profile.bindings,held:Set(values.filter{$0.1}.map{$0.0}),time:now,allowed:paletteAllowed())
        if releaseCheck==nil,gestureRouter.hasPending {
            let work=DispatchWorkItem{[weak self] in self?.releaseCheck=nil;self?.sample()}
            releaseCheck=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.02,execute:work)
        }
        if profile.bindings.contains(where:{$0.mode == .stop && routed.contains($0.id)}) {stop("手柄停止手势");return}
        let paletteBindings=profile.bindings.filter{$0.mode == .palette}
        let paletteInvokers=Set(paletteBindings.map(\.control))
        let activePaletteControls=Set(paletteBindings.filter{routed.contains($0.id)}.map(\.control))
        let paletteValues=values.map{(control,down) in (control,paletteInvokers.contains(control) ? activePaletteControls.contains(control):down)}
        palette.process(values:paletteValues,lx:pad.leftThumbstick.xAxis.value,ly:pad.leftThumbstick.yAxis.value,
                        rx:pad.rightThumbstick.xAxis.value,ry:pad.rightThumbstick.yAxis.value,
                        allowed:paletteAllowed(),invokers:paletteInvokers)
        let captured=palette.captures
        for binding in profile.bindings where binding.mode != .palette && binding.mode != .stop {
            let id=binding.id,down=routed.contains(id),capturedControl=captured.contains(binding.control)
            if capturedControl,let active=activeBindings.removeValue(forKey:id) {output.apply(active,down:false)}
            guard let edge=gate.update(id,down:down,allowed:canSend && !capturedControl) else{continue}
            if edge {activeBindings[id]=binding;output.apply(binding,down:true)}
            else if let active=activeBindings.removeValue(forKey:id){output.apply(active,down:false)}
        }
    }
    func runProbe() {
        stop("本机回环测试")
        NSApp.activate(ignoringOtherApps:true)
        probing=true
        output.probePID=ProcessInfo.processInfo.processIdentifier
        probeResult="正在等待本窗口接收测试键…"; probeToken += 1
        // F18 is sent only to the focused local probe, never to a user's document.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { [weak self] in
            guard let self,self.probing else { return }
            self.output.dryRun=false
            self.output.apply(MappingBinding(.a,.tap,Shortcut(79),"回环"),down:true)
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+1.0) { [weak self] in
            guard let self else { return }
            if self.probing { self.probeResult="本地接收测试未通过；请检查窗口状态与诊断记录"; self.record(self.probeResult) }
            self.probing=false; self.output.probePID=nil; self.output.dryRun=self.dryRun; self.refresh()
        }
    }
    func probeReceived() {
        guard probing else { return }
        probeResult="本地定向投递通过：已收到按下与释放"; record(probeResult); probing=false; writeDiagnostics()
    }
    func writeDiagnostics() {
        let values:[String:Any] = ["version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "development","pid":ProcessInfo.processInfo.processIdentifier,"bundlePath":Bundle.main.bundlePath,"ax":trusted,"postEvent":postAllowed,"signatureValid":signatureValid,"controller":controllerName,"scope":profile.scope.rawValue,"armed":armed,"status":status,"probe":probeResult,
            "settingsPresented":settingsPresented,"settingsSection":settingsSection.rawValue,"dockIconLoaded":TourXboxDelegate.iconLoaded,"dockIconSource":TourXboxDelegate.iconSource,
            "workspaceWindowVisible":workspaceWindow?.isVisible ?? false,"activationPolicy":NSApp.activationPolicy().rawValue,"runInBackground":lifecycle.runInBackground,"loginItemStatus":lifecycle.loginStatus.rawValue,
            "workspaceWindowNumber":workspaceWindow?.windowNumber ?? -1,"paletteControlFrames":palette.controlFrames,
            "paletteVisible":palette.visible,"paletteMode":palette.activeMode,"palettePointerInside":palette.pointerInside,
            "paletteRotationEvents":palette.rotationEvents,"paletteRotationRadians":palette.rotationRadians,
            "paletteEditing":palette.isEditing,"paletteNativeClicks":palette.nativeClicks,"paletteSize":palette.model.preferences.size,"leftStickMaxRadius":maxLeftRadius,
            "leftStickX":controller?.extendedGamepad?.leftThumbstick.xAxis.value ?? 0,"leftStickY":controller?.extendedGamepad?.leftThumbstick.yAxis.value ?? 0,
            "photoshopReads":palette.model.bridge.readCount,"photoshopWrites":palette.model.bridge.writeCount,
            "recentEvents":Array(logs.prefix(24)),
            "photoshopConnected":palette.model.bridge.connected,"photoshopStatus":palette.model.bridge.status,
            "paletteSampling":output.ledger.owners[58]?.contains("dynamic-palette") ?? false,
            "paletteBound":profile.bindings.contains{$0.mode == .palette},"pressed":pressed.map(\.rawValue).sorted()]
        guard let data=try? JSONSerialization.data(withJSONObject:values,options:[.prettyPrinted,.sortedKeys]),data != lastDiagnostics else { return }
        lastDiagnostics=data
        let url=settingsURL.deletingLastPathComponent().appendingPathComponent("diagnostics.json")
        persistenceQueue.async {
            if let i=CommandLine.arguments.firstIndex(of:"--palette-live-check"),CommandLine.arguments.count>i+1 {
                try? data.write(to:URL(fileURLWithPath:CommandLine.arguments[i+1]),options:.atomic)
            }
            try? FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try? data.write(to:url,options:.atomic)
        }
    }
}

#if DEBUG
enum RuntimeTrace {
    static let queue=DispatchQueue(label:"tourXbox.debug.state-trace")
    static func observe(_ publisher:ObservableObjectPublisher,name:String)->AnyCancellable? {
        guard FileManager.default.fileExists(atPath:"/private/tmp/tourXbox-enable-state-trace") else{return nil}
        return publisher.sink {
            let text="\nTRACE \(name) \(Date())\n"+Thread.callStackSymbols.prefix(65).joined(separator:"\n")+"\n"
            queue.async {
                let path="/private/tmp/tourXbox-state-trace.log"
                if !FileManager.default.fileExists(atPath:path){FileManager.default.createFile(atPath:path,contents:nil)}
                if let handle=FileHandle(forWritingAtPath:path){handle.seekToEndOfFile();handle.write(Data(text.utf8));try? handle.close()}
            }
        }
    }
}
#endif
