import SwiftUI
#if DEBUG
import Combine
#endif
#if canImport(MappingCore)
import MappingCore
#endif

@main struct TourXboxApp: App {
    @NSApplicationDelegateAdaptor(TourXboxDelegate.self) private var appDelegate
    @StateObject private var model:ControllerModel
    @StateObject private var editor = BindingEditorCoordinator()
    init(){
        // Launch Services can be bypassed by `open -n` or direct execution. Refuse
        // duplicate versions before any controller handler or settings writer starts.
        let pid=ProcessInfo.processInfo.processIdentifier
        let id=Bundle.main.bundleIdentifier ?? "local.BrushPad.prototype"
        if let existing=NSRunningApplication.runningApplications(withBundleIdentifier:id).first(where:{$0.processIdentifier != pid}) {
            existing.activate(options:[])
            exit(0)
        }
        _model=StateObject(wrappedValue:ControllerModel())
        DispatchQueue.global(qos:.userInitiated).async {_ = XboxArtwork.front;_ = XboxArtwork.top}
    }
    var body: some Scene {
        Window("tourXbox",id:"main") { WorkspaceView(model:model,editor:editor).onAppear{appDelegate.configureStatusMenu(model:model)} }
            .defaultSize(width:940,height:680)
            .windowToolbarStyle(.unified)
            .commands {
                CommandGroup(replacing:.appSettings) {
                    Button("设置…"){model.showSettings(.general)}.keyboardShortcut(",",modifiers:.command)
                }
                CommandGroup(after: .importExport) {
                    Button("导入映射…") { model.importProfile() }
                    Button("导出映射…") { model.exportProfile() }
                }
                CommandMenu("映射") {
                    Button(model.armed ? "暂停映射" : "启用映射") { model.toggleRunning() }
                    Button("预览动态调色盘") { model.palette.showPreview() }
                    Button("关闭动态调色盘") { model.palette.cancel() }.keyboardShortcut(.escape,modifiers:[])
                }
            }

    }
}

struct ContentView: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var editor: BindingEditorCoordinator
    private var followInput:Bool{model.followInput}
    @State private var locatedInput:PadControl?
    var body: some View {
        OfficialControllerView(selected: Binding(get: { model.selected }, set: {
            model.setRecording(false); model.selected=$0; editor.show(model:model,parent:NSApp.keyWindow)
        }), pressed:model.pressed, profile:model.profile, glyphs:model.inputGlyphs, selectionVisible:editor.isPresented || locatedInput == model.selected,editor:editor,status:model.status,scope:model.profile.scope == .global ? "全局" : "指定应用")
            .padding(.horizontal,12).padding(.top,8).padding(.bottom,8)
            .frame(minWidth:680,minHeight:520)
            .navigationTitle("tourXbox")
            .onAppear {
                if CommandLine.arguments.contains("--palette-live-check") {
                    if !model.profile.bindings.contains(where:{$0.mode == .palette}),model.profile.bindings.first(where:{$0.control == .rb})?.mode == .disabled {
                        model.update(MappingBinding(.rb,.palette,Shortcut(58),"动态调色盘"))
                    }
                    if !model.armed {model.toggleRunning()}
                }
                if let i=CommandLine.arguments.firstIndex(of:"--host-read-probe"),CommandLine.arguments.count>i+1 {
                    let url=URL(fileURLWithPath:CommandLine.arguments[i+1])
                    DispatchQueue.global(qos:.userInitiated).async {
                        let started=Date()
                        var report:[String:Any]=["operation":CommandLine.arguments.contains("--verify-color-roundtrip") ? "readWriteRestore":"readOnly","adapter":"macOS Apple Events"]
                        do {
                            let request=PaletteHostRequest(session:"local-read-test",sequence:1,operation:.read)
                            let transport=MacPhotoshopTransport(readTimeout:10)
                            let reply=try transport.exchange(request)
                            report["reply"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(reply))
                            if CommandLine.arguments.contains("--verify-color-roundtrip"),reply.status == .ok,let original=reply.color,let document=reply.documentID {
                                let test=PaletteRGB(0.2,0.4,0.6)
                                defer {_ = try? transport.exchange(PaletteHostRequest(session:request.session,sequence:9,operation:.write,documentID:document,color:original))}
                                let startWrite=Date()
                                _=try transport.exchange(PaletteHostRequest(session:request.session,sequence:2,operation:.write,documentID:document,color:test))
                                report["writeMilliseconds"]=Date().timeIntervalSince(startWrite)*1000
                                let back=try transport.exchange(PaletteHostRequest(session:request.session,sequence:3,operation:.read))
                                report["changedColorReadback"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(back))
                                if let c=back.color {report["testColorMatched"]=max(abs(c.r-test.r),abs(c.g-test.g),abs(c.b-test.b))<1.0/255}
                                _=try transport.exchange(PaletteHostRequest(session:request.session,sequence:4,operation:.write,documentID:document,color:original))
                                let restored=try transport.exchange(PaletteHostRequest(session:request.session,sequence:5,operation:.read))
                                if let c=restored.color {report["originalRestored"]=max(abs(c.r-original.r),abs(c.g-original.g),abs(c.b-original.b))<1.0/255}
                            }
                        } catch {let e=error as NSError;report["errorCode"]=e.code;report["error"]=e.localizedDescription}
                        report["elapsedMilliseconds"]=Date().timeIntervalSince(started)*1000
                        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:url,options:.atomic)}
                        DispatchQueue.main.async{NSApp.terminate(nil)}
                    }
                }
                if let i=CommandLine.arguments.firstIndex(of:"--palette-snapshots"),CommandLine.arguments.count>i+1 {
                    DispatchQueue.main.asyncAfter(deadline:.now()+1) {
                        model.palette.snapshots(to:URL(fileURLWithPath:CommandLine.arguments[i+1])); NSApp.terminate(nil)
                    }
                }
            }
            .onChange(of:model.pressed) { old,new in
                guard followInput, !model.recording, NSApp.isActive,
                      NSApp.keyWindow === model.workspaceWindow, !model.settingsPresented,
                      let control=PadControl.allCases.first(where:{new.subtracting(old).contains($0)}),
                      !PadControl.eliteControls.contains(control) else {return}
                // Only navigate while configuring. Drawing in Photoshop never steals focus.
                if editor.isPresented {editor.close()}
                locatedInput=control; model.selected=control
            }

    }
}

private struct BindingEditor: View {
    @ObservedObject var model: ControllerModel
    var dismiss: () -> Void
    @State private var tab = "custom"
    var body: some View {
        VStack(spacing:0) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:3) {
                    HStack(spacing:8) {
                        ControllerButtonGlyph(control:model.selected,nativeName:model.inputGlyphs[model.selected])
                        Text("按键配置").font(.headline)
                    }.accessibilityLabel(model.selected.title)
                    Text(model.availability(model.selected)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成",action:dismiss).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }.padding(16)
            Picker("配置内容",selection:$tab) {
                Text("快捷键").tag("custom")
                Text("动作库").tag("library")
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal,16).padding(.bottom,12)
            if tab == "custom" {BindingInspector(model:model)}
            else {DrawingActionLibrary(model:model,applied:{tab="custom"})}
            HStack {
                Menu {
                    Button("恢复此按键默认功能") {
                        if let binding=Profile.drawing.bindings.first(where:{$0.id == model.currentBinding.id}) {model.setRecording(false);model.update(binding)}
                    }
                    Button("清除此按键功能") {model.setRecording(false);model.update({var b=model.currentBinding;b.mode = .disabled;return b}())}
                } label: {Label("按键操作",systemImage:"ellipsis.circle")}
                    .menuStyle(.button).buttonStyle(.bordered).fixedSize()
                Spacer()
                Text("更改自动保存").font(.caption).foregroundStyle(.tertiary)
            }.padding(.horizontal,16).padding(.vertical,12)
        }.controlSize(.regular).frame(width:380,height:500)
            .onChange(of:model.selected) {tab="custom"}
            .onChange(of:tab) {model.setRecording(false)}
            .onDisappear { model.setRecording(false) }
    }
}

/// Keyboard equivalents only; these do not claim TourBox/Adobe native integrations.
private struct DrawingActionLibrary:View {
    @ObservedObject var model:ControllerModel
    var applied:()->Void
    @State private var query=""
    private var actions:[MappingBinding] {
        Profile.drawing.bindings.filter {$0.mode != .disabled && $0.mode != .stop}
            .filter {query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || $0.shortcut.display.localizedCaseInsensitiveContains(query)}
    }
    var body:some View {
        VStack(spacing:0) {
            TextField("搜索绘画动作或快捷键",text:$query).textFieldStyle(.roundedBorder).padding(16)
            if actions.isEmpty {
                ContentUnavailableView.search(text:query)
            } else {
                List(actions) {action in
                    Button {
                        model.setRecording(false)
                        model.update(MappingBinding(model.selected,action.mode,action.shortcut,action.label));applied()
                    } label: {
                        HStack {
                            VStack(alignment:.leading,spacing:4){Text(action.label);Text(action.mode.title).font(.caption).foregroundStyle(.secondary)}
                            Spacer()
                            Text(action.shortcut.display).font(.callout.monospaced()).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("使用动作："+action.label)
                }.listStyle(.inset)
            }
            Text("基于 Photoshop 默认快捷键；自定义快捷键可在“快捷键”中录制。")
                .font(.caption).foregroundStyle(.secondary).padding(16)
        }
    }
}

struct BindingInspector: View {
    @ObservedObject var model: ControllerModel
    var showGestures=false
    var body: some View {
        Form {
            Section("按键功能") {
                Picker("当前功能",selection:Binding(get:{model.currentBinding.id},set:{model.selectBinding($0)})) {
                    ForEach(model.selectedBindings){b in
                        Text((b.gesture == .press && b.mode == .hold ? "按住保持":b.gesture.title)+(b.companions.isEmpty ? "":" + "+b.companions.map(\.title).joined(separator:" + "))+" · "+(b.mode == .disabled ? "未分配":b.label)).tag(b.id)
                    }
                }
                HStack {
                    Menu("添加功能") {
                        ForEach(InputGesture.allCases,id:\.self){gesture in
                            Button(gesture.title){model.addBinding(gesture)}
                                .disabled(model.selectedBindings.contains{$0.gesture == gesture && $0.companions.isEmpty})
                        }
                        Menu("组合按键") {
                            ForEach(PadControl.allCases.filter{$0 != model.selected}){control in
                                Button{model.addBinding(.press,companion:control)}label:{HStack{ControllerButtonGlyph(control:control,nativeName:model.inputGlyphs[control]);Text(control.title)}}
                                    .disabled(model.selectedBindings.contains{$0.gesture == .press && $0.companions == [control]})
                            }
                        }
                    }
                    Spacer()
                    Button("移除此功能",role:.destructive){model.removeCurrentBinding()}.disabled(model.selectedBindings.count<2)
                }
            }
            Section {
                if !model.selected.stickInputs.isEmpty {
                    Picker("摇杆输入", selection: $model.selected) {
                        ForEach(model.selected.stickInputs) { ControllerButtonGlyph(control:$0,nativeName:model.inputGlyphs[$0]).accessibilityHidden(false).accessibilityLabel($0.title).tag($0) }
                    }
                }
                if PadControl.eliteControls.contains(model.selected) {
                    Text("Elite 拨片需要设备向系统独立提供输入。普通 Xbox 手柄没有这些按键。").font(.caption).foregroundStyle(.secondary)
                }
                TextField("操作名称", text: Binding(get: { model.currentBinding.label }, set: { model.setLabel($0) }))
                Picker("执行动作", selection: Binding(get: { model.currentBinding.mode }, set: { model.setMode($0) })) {
                    ForEach(ActionMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: { Text("按键") }
            if showGestures {
                Section {
                    Picker("手势",selection:Binding(get:{model.currentBinding.gesture},set:{model.setGesture($0)})) {
                        ForEach(InputGesture.allCases,id:\.self){Text($0.title).tag($0)}
                    }
                    LabeledContent("组合成员") {
                        Menu(model.currentBinding.companions.isEmpty ? "无" : model.currentBinding.companions.map(\.title).joined(separator:" + ")) {
                            ForEach(PadControl.allCases.filter{$0 != model.selected && !$0.rawValue.hasPrefix("stick") && !$0.rawValue.hasPrefix("rightStick")}) {control in
                                Toggle(control.title,isOn:Binding(get:{model.currentBinding.companions.contains(control)},set:{model.setCompanion(control,enabled:$0)}))
                            }
                        }
                    }
                    if !model.currentBinding.companions.isEmpty {
                        Text((model.currentBinding.companions+[model.selected]).map(\.title).joined(separator:" + ")).font(.callout.monospaced())
                    }
                } header:{Text("触发手势")} footer:{Text(model.currentBinding.gesture.explanation + " 同键存在双击功能时，首次长按等待180毫秒；短按不会触发保持动作，第二次按住只执行双击功能。组合最多四个按键。")}
            }
            if model.currentBinding.mode == .palette {
                Section("动态调色盘") {
                    Text("\(model.currentBinding.gesture.title)呼出。左摇杆转圈调色，X 切主模式，Y 切子模式；完整设置在“调色盘”。").font(.caption)
                    Button("预览调色盘") {model.palette.showPreview()}
                }
            } else if model.currentBinding.mode != .stop && model.currentBinding.mode != .disabled {
                Section {
                    ShortcutRecorder(recording: model.recording, shortcut: model.currentBinding.shortcut,
                                     capture: { model.setShortcut($0); model.setRecording(false) },
                                     cancel: { model.setRecording(false) })
                        .frame(height: 30)
                    Button(model.recording ? "取消录制" : "录制快捷键…") { model.setRecording(!model.recording) }
                    Picker("常用按键", selection: Binding<UInt16?>(get: { nil }, set: { if let key = $0 { model.setShortcut(Shortcut(key)); model.setRecording(false) } })) {
                        Text("选择…").tag(Optional<UInt16>.none)
                        Text("Option ⌥").tag(Optional<UInt16>.some(58))
                        Text("Space").tag(Optional<UInt16>.some(49))
                        Text("Shift ⇧").tag(Optional<UInt16>.some(56))
                        Text("Command ⌘").tag(Optional<UInt16>.some(55))
                        Text("Esc").tag(Optional<UInt16>.some(53))
                    }
                } header: { Text("快捷键") } footer: {
                    Text(model.currentBinding.mode == .hold ? "按住手柄时保持，松开时释放。录制时按 Esc 取消。" : "按下手柄时执行一次。录制时按 Esc 取消。")
                }
            }

        }
        .formStyle(.grouped).controlSize(.regular)
    }
}

struct PermissionsView: View {
    @ObservedObject var model:ControllerModel
    var body:some View {
        Form {
            Section("设备") {
                LabeledContent("手柄",value:model.controllerName)
                LabeledContent("当前应用",value:model.frontApp)
            }
            Section {
                LabeledContent("快捷键发送",value:model.canPost ? "可用":"待系统确认")
                Button(model.canPost ? "管理系统权限…":"设置发送权限…") {
                    if !model.canPost {model.requestPermission()}
                    model.openPermissionSettings()
                }
            } header:{Text("权限")} footer:{
                Text("更换构建或安装位置后，可在系统设置中重新确认 tourXbox 的许可。")
            }
            Section {
                Toggle("兼容数位笔修饰键",isOn:Binding(get:{model.profile.bridgePointerFlags},set:{model.setBridge($0)}))
            } header:{Text("数位笔")} footer:{
                Text("用于数位笔绘画时保持 Option、Shift 等修饰键。")
            }
        }.formStyle(.grouped)
    }
}

enum SettingsSection:String,CaseIterable {
    case mapping,palette,general,devices
    var title:String {switch self{case .mapping:"按键与手势";case .palette:"动态调色盘";case .general:"通用";case .devices:"设备与权限"}}
    var symbol:String {switch self{case .mapping:"gamecontroller";case .palette:"paintpalette";case .general:"gearshape";case .devices:"antenna.radiowaves.left.and.right"}}
}
struct WorkspaceView:View {
    @ObservedObject var model:ControllerModel
    @ObservedObject var editor:BindingEditorCoordinator
    var body:some View {
        ContentView(model:model,editor:editor)
            .background(Color(nsColor:.windowBackgroundColor))
            .background(WorkspaceWindowReader{model.workspaceWindow=$0})
            .toolbar {
                if #available(macOS 26.0,*) {
                    ToolbarItem(placement:.primaryAction){
                        Button{model.toggleRunning()}label:{Label(model.armed ? "暂停映射":"启用映射",systemImage:model.armed ? "pause.fill":"play.fill").labelStyle(.iconOnly).font(.system(size:17,weight:.regular)).frame(width:20,height:20)}
                            .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                            .help(model.armed ? "暂停映射并释放所有按键":"启用绘画映射")
                    }.sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.fixed,placement:.primaryAction)
                    ToolbarItem(placement:.primaryAction){
                        Button{editor.close();model.showSettings(.general)}label:{Label("设置",systemImage:"gearshape").labelStyle(.iconOnly).font(.system(size:17,weight:.regular)).frame(width:20,height:20)}
                            .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large).help("设置（⌘,）")
                    }.sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement:.primaryAction){Button{model.toggleRunning()}label:{Label(model.armed ? "暂停映射":"启用映射",systemImage:model.armed ? "pause":"play").labelStyle(.iconOnly)}}
                    ToolbarItem(placement:.primaryAction){Button{editor.close();model.showSettings(.general)}label:{Label("设置",systemImage:"gearshape").labelStyle(.iconOnly)}}
                }
            }
            .controlSize(.regular)
            .frame(minWidth:820,minHeight:600)
            .sheet(isPresented:$model.settingsPresented){SettingsSheet(model:model,editor:editor)}
            .alert("无法完成操作",isPresented:Binding(get:{!model.settingsPresented && model.errorMessage != nil},set:{if !$0 {model.errorMessage=nil}})) {
                Button("好"){model.errorMessage=nil}
            } message:{Text(model.errorMessage ?? "")}
    }
}
private struct SettingsSheet:View {
    @ObservedObject var model:ControllerModel
    @ObservedObject var editor:BindingEditorCoordinator
    @State private var panelSize:CGSize
    init(model:ControllerModel,editor:BindingEditorCoordinator){
        self.model=model;self.editor=editor
        _panelSize=State(initialValue:Self.fittedSize(model.workspaceWindow))
    }
    private static func fittedSize(_ window:NSWindow?)->CGSize {
        let available=window?.contentLayoutRect.size ?? CGSize(width:940,height:680)
        return CGSize(width:min(820,max(720,available.width-48)),height:min(620,max(440,available.height-64)))
    }
    private func fitToParent(){
        let next=Self.fittedSize(model.workspaceWindow)
        if panelSize != next{panelSize=next}
    }
    var body:some View {
        NavigationSplitView {
            List(SettingsSection.allCases,id:\.self,selection:Binding<SettingsSection?>(get:{model.settingsSection},set:{value in
                guard let value,value != model.settingsSection else{return}
                // AppKit can reconcile List selection while SwiftUI is updating its view tree.
                DispatchQueue.main.async {
                    if model.settingsSection != value {model.settingsSection=value}
                }
            })) {section in
                Label(section.title,systemImage:section.symbol).tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min:170,ideal:185,max:210)
            .navigationTitle("设置")
        } detail: {
            NavigationStack {
                Group {
                    switch model.settingsSection {
                    case .mapping:VStack(spacing:0){mappingScope;AllMappingsSettings(model:model,editor:editor)}
                    case .palette:PalettePreferencesView(coordinator:model.palette,controller:model)
                    case .general:general
                    case .devices:PermissionsView(model:model)
                    }
                }
                .navigationTitle(model.settingsSection.title)
                .toolbar {
                    ToolbarItem(placement:.confirmationAction) {
                        Button("完成"){model.setRecording(false);model.settingsPresented=false}
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width:panelSize.width,height:panelSize.height)
        .onAppear{DispatchQueue.main.async{editor.close()}}
        .onReceive(NotificationCenter.default.publisher(for:NSWindow.didResizeNotification)){notification in
            if let window=notification.object as? NSWindow,window === model.workspaceWindow{DispatchQueue.main.async{fitToParent()}}
        }
        .onDisappear{model.setRecording(false)}
        .onChange(of:model.settingsSection){model.setRecording(false)}
        .confirmationDialog("恢复绘画默认映射？",isPresented:$model.confirmReset,titleVisibility:.visible){
            Button("恢复默认",role:.destructive){model.resetProfile()}
        }message:{Text("当前配置会被替换，可先导出备份。")}
        .alert("无法完成操作",isPresented:Binding(get:{model.errorMessage != nil},set:{if !$0 {model.errorMessage=nil}})){
            Button("好"){model.errorMessage=nil}
        }message:{Text(model.errorMessage ?? "")}
    }
    private var mappingScope:some View {
        HStack(spacing:16){
            Picker("映射范围",selection:Binding(get:{model.profile.scope},set:{model.setScope($0)})){
                Text("全局").tag(MappingScope.global);Text("指定应用").tag(MappingScope.application)
            }.frame(width:220)
            if model.profile.scope == .application {
                Picker("应用",selection:Binding(get:{model.profile.targetBundleID},set:{model.setTarget($0)})){
                    ForEach(model.appChoices,id:\.1){Text($0.0).tag($0.1)}
                }.onAppear{model.updateAppChoices()}
            }
            Spacer(minLength:0)
        }.padding(16)
    }
    private var general:some View {
        Form{
            Section("控制器界面"){
                Toggle("按手柄定位到对应按键",isOn:Binding(get:{model.followInput},set:{model.setFollowInput($0)}))
            }
            Section("配置文件"){
                HStack{Button("导入…"){model.importProfile()};Button("导出…"){model.exportProfile()};Spacer()}
                Button("恢复绘画默认映射…",role:.destructive){model.confirmReset=true}
            }
            Section("关于"){LabeledContent("tourXbox",value:"0.22.1");LabeledContent("默认调色盘呼出",value:"LT · 双击后长按")}
        }.formStyle(.grouped)
    }
}
private struct AllMappingsSettings:View {
    @ObservedObject var model:ControllerModel
    @ObservedObject var editor:BindingEditorCoordinator
    @State private var filter=""
    var body:some View {
        HSplitView {
            VStack(spacing:12) {
                TextField("搜索按键或功能",text:$filter).textFieldStyle(.roundedBorder).padding(.horizontal,12).padding(.top,14)
                List(selection:Binding<PadControl?>(get:{model.selected},set:{value in
                    guard let value,value != model.selected else{return}
                    DispatchQueue.main.async{model.selected=value}
                })) {
                    ForEach(PadControl.allCases.filter{control in filter.isEmpty || control.title.localizedCaseInsensitiveContains(filter) || model.profile.bindings.contains{$0.control == control && $0.label.localizedCaseInsensitiveContains(filter)}}) {control in
                        let configured=model.profile.bindings.filter{$0.control == control && $0.mode != .disabled}
                        VStack(alignment:.leading,spacing:4) {
                            ControllerButtonGlyph(control:control,nativeName:model.inputGlyphs[control]).accessibilityHidden(false).accessibilityLabel(control.title)
                            Text(configured.isEmpty ? "未分配":configured.map(\.label).joined(separator:"／")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if !configured.isEmpty {Text("\(configured.count) 项功能").font(.caption2).foregroundStyle(.tertiary)}
                        }.padding(.vertical,3).tag(control)
                    }
                }.listStyle(.inset)
            }.frame(minWidth:170,idealWidth:190,maxWidth:220)
            BindingInspector(model:model,showGestures:true).frame(minWidth:390,maxWidth:.infinity)
        }
    }
}

extension ActionMode {
    var title: String {
        switch self { case .hold: return "按住保持"; case .tap: return "单次执行"; case .palette: return "动态调色盘"; case .stop: return "停止映射"; case .disabled: return "不分配" }
    }
}

private enum XboxArtwork {
    #if SWIFT_PACKAGE
    static let bundle = Bundle.module
    #else
    static let bundle = Bundle.main
    #endif
    static let front = load("xbox-front")
    static let top = load("xbox-top")
    private static func load(_ name: String) -> NSImage? {
        guard let url = bundle.url(forResource: name, withExtension: "jpg", subdirectory: "Resources") else { return nil }
        guard let source=NSImage(contentsOf:url),let cgImage=source.cgImage(forProposedRect:nil,context:nil,hints:nil),
              let cutout=XboxArtworkCutout.make(cgImage) else {return nil}
        return NSImage(cgImage:cutout,size:NSSize(width:cutout.width,height:cutout.height))
    }
}

struct OfficialControllerView: View {
    @Binding var selected: PadControl
    var pressed: Set<PadControl>
    var profile: Profile
    var glyphs:[PadControl:String]
    var selectionVisible: Bool
    let editor:BindingEditorCoordinator
    var status:String
    var scope:String
    @State private var showFunctions = UserDefaults.standard.bool(forKey:"controller.showFunctions")
    @State private var presentation = UserDefaults.standard.string(forKey:"controller.presentation") ?? "front"
    @State private var sceneProgress=0.0
    @State private var annotationOpacity=0.0
    @State private var transitionRevision=0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let shoulders: Set<PadControl> = [.lt,.lb,.rt,.rb]
    var body: some View {
        VStack(spacing:4) {
            HStack(alignment:.center,spacing:12) {
                Text(presentation == "shoulders" ? "肩键" : "正面").font(.headline)
                Text("\(Set(profile.bindings.filter{$0.mode != .disabled}.map(\.control)).count) 个输入已配置").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("显示功能",isOn:$showFunctions).toggleStyle(.switch).controlSize(.regular).fixedSize()
            }.padding(.bottom,4)
            GeometryReader {geo in
                ZStack(alignment:.top) {
                        if presentation == "shoulders" {
                            pageContent(top:true,size:CGSize(width:geo.size.width,height:max(1,geo.size.height-30)))
                                .transition(.asymmetric(insertion:.move(edge:.top),removal:.move(edge:.top)))
                        } else {
                            pageContent(top:false,size:CGSize(width:geo.size.width,height:max(1,geo.size.height-30)))
                                .transition(.asymmetric(insertion:.move(edge:.bottom),removal:.move(edge:.bottom)))
                        }
                    }.frame(width:geo.size.width,height:geo.size.height).clipped()
                        .background(ControllerWheelBridge {direction in changePage(direction>0 ? "shoulders":"front")})
                        .accessibilityElement(children:.contain).accessibilityLabel("控制器视角："+(presentation == "shoulders" ? "肩键":"正面"))
            }.onChange(of:selected){changePage(shoulders.contains(selected.diagramAnchor) ? "shoulders":"front")}
                .overlay(alignment:.bottom){footer}


        }
        .onAppear {
            if presentation != "front" && presentation != "shoulders" {presentation="front"}
            sceneProgress=showFunctions ? 1:0;annotationOpacity=showFunctions ? 1:0
        }
        .onChange(of:showFunctions){_,enabled in
            DispatchQueue.main.async{UserDefaults.standard.set(enabled,forKey:"controller.showFunctions")}
            transitionFunctions(to:enabled)
        }
    }
    private var footer:some View {
HStack {
                Label(status,systemImage:"gamecontroller").lineLimit(1)
                Text("· \(scope)")
                Spacer(minLength:8)
                Text("点击按键配置 · 双指滑动切换视角").lineLimit(1)
                Link(destination:URL(string:"https://www.xbox.com/en-US/accessories/controllers/xbox-wireless-controller")!) {
                    Image(systemName:"info.circle").frame(width:32,height:32).contentShape(Rectangle())
                }.help("Xbox 官方图像来源").accessibilityLabel("Xbox 官方图像来源")
            }.font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal,4).padding(.bottom,2)
    }
    private func pageContent(top:Bool,size:CGSize) -> some View {
        ControllerCanvas(selected:$selected,pressed:pressed,profile:profile,glyphs:glyphs,selectionVisible:selectionVisible,topView:top,showFunctions:showFunctions,editor:editor,progress:sceneProgress,annotationOpacity:annotationOpacity,annotations:ControllerDiagram.annotations(top:top,profile:profile),annotatedViewport:ControllerDiagram.viewport(profile:profile,annotated:true))
            .frame(width:size.width,height:size.height)
    }
    private func transitionFunctions(to enabled:Bool){
        transitionRevision += 1
        let revision=transitionRevision
        if reduceMotion {sceneProgress=enabled ? 1:0;annotationOpacity=enabled ? 1:0;return}
        if enabled {
            annotationOpacity=0
            withAnimation(.smooth(duration:0.22,extraBounce:0),completionCriteria:.removed){sceneProgress=1} completion:{
                DispatchQueue.main.async {
                    guard transitionRevision==revision,showFunctions else{return}
                    withAnimation(.easeOut(duration:0.08)){annotationOpacity=1}
                }
            }
        } else {
            withAnimation(.easeOut(duration:0.06),completionCriteria:.removed){annotationOpacity=0} completion:{
                DispatchQueue.main.async {
                    guard transitionRevision==revision,!showFunctions else{return}
                    withAnimation(.smooth(duration:0.22,extraBounce:0)){sceneProgress=0}
                }
            }
        }
    }
    private func changePage(_ page:String){
        guard page != presentation else{return}
        withAnimation(reduceMotion ? nil:.snappy(duration:0.24,extraBounce:0)){presentation=page}
        DispatchQueue.main.async{UserDefaults.standard.set(page,forKey:"controller.presentation")}
    }
}

/// Each gesture requests a discrete page transition; there is no shared scroll canvas.
private struct ControllerWheelBridge:NSViewRepresentable {
    var turn:(Int)->Void
    final class WheelView:NSView {
        var turn:((Int)->Void)?
        var monitor:Any?
        var lastTime=0.0
        var lastDirection=0
        var accumulated:CGFloat=0
        var gestureFired=false
        override func hitTest(_ point:NSPoint)->NSView?{nil}
        override func viewDidMoveToWindow(){
            super.viewDidMoveToWindow()
            if let monitor {NSEvent.removeMonitor(monitor);self.monitor=nil}
            guard window != nil else{return}
            monitor=NSEvent.addLocalMonitorForEvents(matching:.scrollWheel){[weak self] event in
                guard let self,event.window === self.window,
                      self.visibleRect.contains(self.convert(event.locationInWindow,from:nil)),abs(event.scrollingDeltaY)>0.01 else{return event}
                let direction=event.scrollingDeltaY>0 ? 1:-1,now=ProcessInfo.processInfo.systemUptime
                if event.hasPreciseScrollingDeltas {
                    if !event.momentumPhase.isEmpty {return nil}
                    if event.phase.contains(.began) || now-self.lastTime>0.25 {self.accumulated=0;self.gestureFired=false}
                    self.lastTime=now;self.accumulated += event.scrollingDeltaY
                    if !self.gestureFired,abs(self.accumulated)>=12 {self.gestureFired=true;self.turn?(self.accumulated>0 ? 1:-1)}
                    if event.phase.contains(.ended) || event.phase.contains(.cancelled) {self.accumulated=0;self.gestureFired=false}
                } else if now-self.lastTime>0.18 || direction != self.lastDirection {
                    self.lastTime=now;self.lastDirection=direction;self.turn?(direction)
                }
                return nil
            }
        }
        func stop(){if let monitor{NSEvent.removeMonitor(monitor);self.monitor=nil}}
    }
    func makeNSView(context:Context)->WheelView{let view=WheelView();view.turn=turn;return view}
    func updateNSView(_ view:WheelView,context:Context){view.turn=turn}
    static func dismantleNSView(_ view:WheelView,coordinator:()){view.stop()}
}

private struct ControllerCanvas: View,Animatable {
    @Binding var selected: PadControl
    var pressed: Set<PadControl>
    var profile: Profile
    var glyphs:[PadControl:String]
    var selectionVisible: Bool
    var topView: Bool
    var showFunctions: Bool
    let editor:BindingEditorCoordinator
    var progress:Double
    var annotationOpacity:Double
    var annotations:[ControllerAnnotation]
    var annotatedViewport:DiagramRect
    var animatableData:AnimatablePair<Double,Double> {
        get{.init(progress,annotationOpacity)}
        set{progress=newValue.first;annotationOpacity=newValue.second}
    }
    var body: some View {
        GeometryReader { geo in
            let crop=ControllerDiagram.transitionViewport(target:annotatedViewport,progress:progress)
            let chartScale=min((geo.size.width-16)/crop.width,(geo.size.height-16)/crop.height)
            let origin=CGPoint(x:(geo.size.width-crop.width*chartScale)/2-crop.x*chartScale,y:(geo.size.height-crop.height*chartScale)/2-crop.y*chartScale)
            let finalCrop=annotatedViewport
            let labelScale=min((geo.size.width-16)/finalCrop.width,(geo.size.height-16)/finalCrop.height)
            let labelOrigin=CGPoint(x:(geo.size.width-finalCrop.width*labelScale)/2-finalCrop.x*labelScale,y:(geo.size.height-finalCrop.height*labelScale)/2-finalCrop.y*labelScale)
            let surfaces=[ControllerSurface(top:topView,photo:ControllerDiagram.transitionPhoto(top:topView,progress:progress))]
            ZStack(alignment:.topLeading) {
                ForEach(surfaces) { surface in
                    let photo=surface.photo
                    let width=photo.width*chartScale
                    let height=photo.height*chartScale
                    let scale=width/ControllerLayout.width
                    let points=surface.top ? ControllerLayout.intuitiveTop : ControllerLayout.front
                    ZStack(alignment:.topLeading) {
                        if let image=surface.top ? XboxArtwork.top : XboxArtwork.front {
                            Image(nsImage:image).resizable().interpolation(.high).frame(width:width,height:height)
                                .rotationEffect(.degrees(surface.top ? 180 : 0))
                                .accessibilityLabel(surface.top ? "Xbox 官方肩键照片，旋转 180 度" : "Xbox 官方控制器正面照片")
                        }
                        ForEach(points) { point in
                            let active=pressed.contains { $0.diagramAnchor == point.control }
                            let chosen=selectionVisible && selected.diagramAnchor == point.control
                            let configured = !profile.configuredBindings(at:point.control).isEmpty
                            Button { selected=point.control } label: {
                                ControllerSelectionShape(control:point.control,shoulder:surface.top)
                                    .fill(Color.accentColor.opacity(active ? 0.42 : chosen ? 0.22 : 0))
                                    .overlay(ControllerSelectionShape(control:point.control,shoulder:surface.top)
                                        .stroke(chosen ? Color.accentColor : configured ? Color.accentColor.opacity(0.35) : .clear,lineWidth:chosen ? 2 : 0.8))
                                    .contentShape(ControllerSelectionShape(control:point.control,shoulder:surface.top))
                            }.buttonStyle(.plain)
                                .frame(width:(surface.top ? 270 : point.diameter)*scale,height:(surface.top ? 250 : point.height)*scale)
                                .background(EditorPopoverAnchor(editor:editor,control:point.control))
                                .position(x:point.x*scale,y:point.y*scale)
                                .help(mappingDescription(point.control)).accessibilityLabel("选择 \(point.control.title)")
                        }
                    }.frame(width:width,height:height).position(x:origin.x+(photo.x+photo.width/2)*chartScale,y:origin.y+(photo.y+photo.height/2)*chartScale)
                }
                  // Stable layout: only this layer's opacity changes, never its positions.
                  ZStack(alignment:.topLeading) {
                    ForEach(annotations) { annotation in
                        let chosen = selectionVisible && ControllerDiagram.annotationControls(annotation.control).contains(selected.diagramAnchor)
                        let groupControls=ControllerDiagram.annotationControls(annotation.control).filter{!profile.configuredBindings(at:$0).isEmpty}
                        let groupHeight=max(44,annotation.label.height*labelScale)
                        let rowHeight=groupHeight/Double(max(1,groupControls.count))
                        Path { path in
                            for route in ControllerDiagram.leaderRoutes(for:annotation,top:topView,profile:profile,rowSpacing:rowHeight/labelScale) {
                                let points=route.map{CGPoint(x:labelOrigin.x+$0.x*labelScale,y:labelOrigin.y+$0.y*labelScale)}
                                if let first=points.first {path.move(to:first);for point in points.dropFirst(){path.addLine(to:point)}}
                            }
                        }.stroke(chosen ? Color.accentColor : Color.primary.opacity(0.4),style:StrokeStyle(lineWidth:chosen ? 1.5 : 1,lineCap:.round,lineJoin:.round))
                            .allowsHitTesting(false)
                        Group {
                            if [.left,.up].contains(annotation.control) {
                                VStack(alignment:labelAlignment(annotation),spacing:0) {
                                    ForEach(groupControls){control in
                                        if !profile.configuredBindings(at:control).isEmpty {
                                            Button{selected=control}label:{
                                                HStack(spacing:6){
                                                    ControllerButtonGlyph(control:control,nativeName:glyphs[control])
                                                    Text(functionSummary(control)).font(.system(size:13,weight:.medium)).lineLimit(1)
                                                    Text(shortcutSummary(control)).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                                }.frame(height:rowHeight)
                                            }.help(mappingDescription(control)).accessibilityLabel("配置功能 \(control.title)：\(functionSummary(control))")
                                        }
                                    }
                                }
                            } else {
                                Button {selected=annotation.control}label:{
                                    VStack(alignment:labelAlignment(annotation),spacing:3) {
                                        HStack(spacing:6) {
                                            ControllerButtonGlyph(control:annotation.control,nativeName:glyphs[annotation.control])
                                                .foregroundStyle(chosen ? Color.accentColor:.primary)
                                            Text(shortcutSummary(annotation.control)).font(.system(size:11,weight:.medium,design:.monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Text(functionSummary(annotation.control)).font(.system(size:14,weight:.medium)).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                                    }
                                }.help(mappingDescription(annotation.control)).accessibilityLabel("配置功能 \(annotation.control.title)：\(functionSummary(annotation.control))")
                            }
                        }.buttonStyle(.plain)
                            .frame(width:annotation.label.width*labelScale,height:max(44,annotation.label.height*labelScale),alignment:frameAlignment(annotation))
                            .position(x:labelOrigin.x+(annotation.label.x+annotation.label.width/2)*labelScale,y:labelOrigin.y+(annotation.label.y+annotation.label.height/2)*labelScale)
                    }
                  }.frame(width:geo.size.width,height:geo.size.height,alignment:.topLeading)
                    .opacity(annotationOpacity)
                    .allowsHitTesting(showFunctions && annotationOpacity>0.99)
                    .accessibilityHidden(!showFunctions || annotationOpacity<0.99)
                    .zIndex(2)
            }.frame(width:geo.size.width,height:geo.size.height)
        }
    }
    private func labelAlignment(_ annotation:ControllerAnnotation) -> HorizontalAlignment {
        guard let end=annotation.route.last else {return .leading}
        if end.x >= annotation.label.x+annotation.label.width {return .trailing}
        if end.x <= annotation.label.x {return .leading}
        return .center
    }
    private func frameAlignment(_ annotation:ControllerAnnotation) -> Alignment {
        let alignment=labelAlignment(annotation)
        return alignment == .trailing ? .trailing : alignment == .center ? .center : .leading
    }
    private func functionSummary(_ control: PadControl) -> String {
        let bindings=profile.configuredBindings(at:control)
        return bindings.isEmpty ? "未分配" : bindings.map { ($0.control.directionGlyph.map { $0 + " " } ?? "") + ($0.label.isEmpty ? "快捷键" : $0.label) }.joined(separator: "／")
    }
    private func shortcutSummary(_ control: PadControl) -> String {
        profile.configuredBindings(at: control).map { $0.mode == .stop ? "停止映射" : $0.mode == .palette ? $0.gesture.title : $0.shortcut.display }.joined(separator: " · ")
    }
    private func mappingDescription(_ control: PadControl) -> String {
        let bindings = profile.configuredBindings(at: control)
        return control.title + (bindings.isEmpty ? " · 未配置" : " · " + bindings.map {
            $0.control.title + "：" + ($0.label.isEmpty ? "快捷键" : $0.label) + " " + ($0.mode == .stop ? "停止映射" : $0.mode == .palette ? $0.gesture.title : $0.shortcut.display)
        }.joined(separator: "；"))
    }
}

/// Paths follow the physical shoulder silhouette in the original official image.
/// Rotate points with the photo, instead of mirroring labels or changing input identity.
private struct ControllerSelectionShape: Shape {
    let control: PadControl
    let shoulder: Bool
    func path(in rect: CGRect) -> Path {
        guard shoulder, let original = ControllerLayout.originalTop.first(where: { $0.control == control }) else {
            if [.left,.right,.up,.down,.share].contains(control) {
                return Path(roundedRect: rect, cornerRadius: control == .share ? rect.height / 2 : 5 * rect.width / 48)
            }
            return Path(ellipseIn: rect)
        }
        let trigger = control == .lt || control == .rt
        // Left image half is the physical right hand. Reflect only the contour template.
        let template: [(Double,Double)] = trigger
            ? [(220,251),(272,249),(335,259),(392,279),(393,338),(379,398),(351,433),(305,446),(263,431),(233,399),(219,342)]
            : [(230,231),(247,183),(282,155),(344,133),(420,122),(489,121),(490,252),(405,253),(340,240),(282,237)]
        let rightHalf = control == .lt || control == .lb
        let points = template.map { x,y -> CGPoint in
            let sourceX = rightHalf ? ControllerLayout.width-x : x
            let localX = -(sourceX-original.x) + 135
            let localY = -(y-original.y) + 125
            return CGPoint(x: localX/270 * rect.width, y: localY/250 * rect.height)
        }
        var path = Path()
        path.addLines(points); path.closeSubpath()
        return path
    }
}

/// One native popover; picture buttons register their own actual NSView anchors.
@MainActor final class BindingEditorCoordinator: NSObject, ObservableObject, NSPopoverDelegate {
    @Published private(set) var isPresented=false
    private var popover:NSPopover?
    private weak var model:ControllerModel?
    private var anchors:[Int:[String:WeakEditorAnchor]]=[:]
    private var shownControl:PadControl?
    private var outsideMonitor:Any?
    private var deactivateObserver:NSObjectProtocol?
    #if DEBUG
    private var debugTrace:AnyCancellable?
    #endif
    override init(){
        super.init()
        #if DEBUG
        debugTrace=RuntimeTrace.observe(objectWillChange,name:"BindingEditor")
        #endif
        outsideMonitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.keyDown]){[weak self] event in
            guard let self,let popover=self.popover,popover.isShown else{return event}
            if event.type == .keyDown {
                if event.keyCode == 53,self.model?.recording != true {self.close();return nil}
                return event
            }
            if event.window === popover.contentViewController?.view.window {return event}
            let targets=self.anchors.values.flatMap{$0.values}.compactMap(\.view)
            let hitsAnchor=targets.contains{view in view.window === event.window && view.visibleRect.contains(view.convert(event.locationInWindow,from:nil))}
            if !hitsAnchor {self.close()}
            return event
        }
        deactivateObserver=NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:.main){[weak self] _ in
            Task{@MainActor in self?.close()}
        }
    }
    func register(_ view:NSView,control:PadControl? = nil) {
        guard let window=view.window else {return}
        anchors[window.windowNumber,default:[:]][control?.rawValue ?? "toolbar"]=WeakEditorAnchor(view)
    }
    func show(model:ControllerModel,parent:NSWindow?) {
        self.model=model
        if popover == nil {
            let window=NSPopover()
            window.behavior = .applicationDefined
            window.animates=true
            window.delegate=self
            window.contentSize=NSSize(width:380,height:500)
            window.contentViewController=NSHostingController(rootView:BindingEditor(model:model,dismiss:{[weak self] in self?.close()}))
            popover=window
        }
        guard let popover else {return}
        let control=model.selected.diagramAnchor
        if popover.isShown && shownControl == control {isPresented=true;return}
        let controls=anchors.values.compactMap {$0[control.rawValue]?.view}
        let toolbars=anchors.values.compactMap {$0["toolbar"]?.view}
        let anchor=controls.first {$0.window === parent && $0.window?.isVisible == true}
            ?? controls.first {$0.window?.isVisible == true && !$0.visibleRect.isEmpty}
            ?? toolbars.first {$0.window === parent}
            ?? toolbars.first {$0.window?.isVisible == true}
        guard let anchor else {return}
        shownControl=control
        isPresented=true
        // Prefer the same edge, while keeping the native arrow attached to the actual selected control.
        let moving=popover.isShown
        popover.animates = !moving
        popover.show(relativeTo:anchor.bounds,of:anchor,preferredEdge:.minY)
        popover.animates=true
    }
    func close() {popover?.performClose(nil)}
    func popoverDidClose(_ notification:Notification) {isPresented=false;model?.setRecording(false)}
}
private final class WeakEditorAnchor {
    weak var view:NSView?
    init(_ view:NSView) {self.view=view}
}
private struct EditorPopoverAnchor:NSViewRepresentable {
    let editor:BindingEditorCoordinator
    var control:PadControl? = nil
    func makeNSView(context:Context) -> AnchorView {let view=AnchorView();view.editor=editor;view.control=control;return view}
    func updateNSView(_ view:AnchorView,context:Context) {view.editor=editor;view.control=control;editor.register(view,control:control)}
    final class AnchorView:NSView {
        weak var editor:BindingEditorCoordinator?
        var control:PadControl?
        override func viewDidMoveToWindow() {super.viewDidMoveToWindow();editor?.register(self,control:control)}
        override func hitTest(_ point:NSPoint) -> NSView? {nil}
    }
}



/// Static artwork preparation. Flood only exterior paper, keeping enclosed white logos opaque.
/// Original source pixels, dimensions and controller coordinates are retained; no image generation.
enum XboxArtworkCutout {
    static func make(_ source:CGImage) -> CGImage? {
        let width=source.width,height=source.height,count=width*height
        var pixels=[UInt8](repeating:0,count:count*4)
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        let info=CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let decoded=pixels.withUnsafeMutableBytes { data -> Bool in
            guard let context=CGContext(data:data.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:info) else {return false}
            context.draw(source,in:CGRect(x:0,y:0,width:width,height:height));return true
        }
        guard decoded else {return nil}
        var paper=[Bool](repeating:false,count:count)
        var queue=[Int]();queue.reserveCapacity(count)
        func brightness(_ i:Int)->Int {let p=i*4;return Int(min(pixels[p],min(pixels[p+1],pixels[p+2])))}
        func enqueue(_ i:Int) {
            // The front photo has a contact shadow below its grips; do not retain it as opaque paper.
            let cutoff=i/width > height*5/6 ? 100 : 180
            guard !paper[i],brightness(i)>cutoff else {return}
            paper[i]=true;queue.append(i)
        }
        for x in 0..<width {enqueue(x);enqueue((height-1)*width+x)}
        for y in 0..<height {enqueue(y*width);enqueue(y*width+width-1)}
        var head=0
        while head<queue.count {
            let i=queue[head],x=i%width;head+=1
            if x>0 {enqueue(i-1)}
            if x+1<width {enqueue(i+1)}
            if i>=width {enqueue(i-width)}
            if i+width<count {enqueue(i+width)}
        }
        let original=pixels
        for i in 0..<count {
            let x=i%width,y=i/width,p=i*4
            var exteriorNeighbor=paper[i]
            if !exteriorNeighbor && x>0 && x+1<width && y>0 && y+1<height {
                exteriorNeighbor=paper[i-1] || paper[i+1] || paper[i-width] || paper[i+width]
            }
            guard exteriorNeighbor else {continue}
            var reference=255
            for yy in max(0,y-2)...min(height-1,y+2) {
                for xx in max(0,x-2)...min(width-1,x+2) {
                    let j=yy*width+xx
                    if !paper[j] {let q=j*4;reference=min(reference,Int(min(original[q],min(original[q+1],original[q+2]))))}
                }
            }
            guard reference<180 else {pixels[p]=0;pixels[p+1]=0;pixels[p+2]=0;pixels[p+3]=0;continue}
            let observed=Int(min(original[p],min(original[p+1],original[p+2])))
            let alpha=max(0,min(1,Double(255-observed)/Double(255-reference)))
            if alpha<0.02 {pixels[p]=0;pixels[p+1]=0;pixels[p+2]=0;pixels[p+3]=0;continue}
            // Remove the white matte in premultiplied space to avoid a pale outline on dark backgrounds.
            for channel in 0..<3 {
                pixels[p+channel]=UInt8(max(0,min(255,Double(original[p+channel])-255*(1-alpha))).rounded())
            }
            pixels[p+3]=UInt8((alpha*255).rounded())
        }
        guard let provider=CGDataProvider(data:Data(pixels) as CFData) else {return nil}
        return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:space,bitmapInfo:CGBitmapInfo(rawValue:info),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
    }
}

/// Apple controller symbols. Native physical glyphs take precedence; validate fallbacks on this OS.
struct ControllerButtonGlyph:View {
    let control:PadControl
    var nativeName:String?
    private var symbol:String {
        let name:String
        switch control.diagramAnchor {
        case .a:name="a.circle";case .b:name="b.circle";case .x:name="x.circle";case .y:name="y.circle"
        case .left:name="dpad.left.filled";case .right:name="dpad.right.filled"
        case .up:name="dpad.up.filled";case .down:name="dpad.down.filled"
        case .view:name="rectangle.on.rectangle";case .menu:name="line.3.horizontal.circle"
        case .l3:name="l.joystick.press.down";case .r3:name="r.joystick.press.down"
        case .lt:name="lt.rectangle.roundedtop";case .rt:name="rt.rectangle.roundedtop"
        case .lb:name="lb.rectangle.roundedbottom";case .rb:name="rb.rectangle.roundedbottom"
        case .share:name="square.and.arrow.up";case .home:name="xbox.logo"
        default:name="gamecontroller"
        }
        // A directional D-pad icon must communicate which physical direction is selected.
        if ![.left,.right,.up,.down].contains(control),let nativeName,NSImage(systemSymbolName:nativeName,accessibilityDescription:nil) != nil {return nativeName}
        return NSImage(systemSymbolName:name,accessibilityDescription:nil) != nil ? name : "gamecontroller"
    }
    var body:some View {
        HStack(spacing:2){
            if PadControl.eliteControls.contains(control) {Text(String(control.title.prefix(2))).font(.caption.monospaced().weight(.semibold))}
            else {Image(systemName:symbol).resizable().scaledToFit().frame(width:24,height:20)}
            if let direction=control.directionGlyph {Text(direction).font(.caption2.weight(.semibold))}
        }.accessibilityHidden(true)
    }
}


extension InputGesture {
    var title:String {switch self {case .press:return "按下";case .doubleTap:return "双击";case .doubleHold:return "双击后长按"}}
    var explanation:String {switch self {
    case .press:return "单独配置时按下即触发，保持型动作随松开结束。"
    case .doubleTap:return "第一次松开后 320 毫秒内再次按下，执行一次。"
    case .doubleHold:return "按一下并松开，320 毫秒内再次按下并保持 180 毫秒，松开结束。"
    }}
}


@MainActor final class TourXboxDelegate:NSObject,NSApplicationDelegate,NSMenuDelegate {
    private var statusItem:NSStatusItem?
    private weak var controller:ControllerModel?
    func configureStatusMenu(model:ControllerModel){
        controller=model
        guard statusItem == nil else{return}
        let item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        item.button?.image=NSImage(systemSymbolName:"gamecontroller",accessibilityDescription:"tourXbox")
        let menu=NSMenu();menu.delegate=self;item.menu=menu;statusItem=item
    }
    func menuWillOpen(_ menu:NSMenu){
        guard let controller else{return}
        menu.removeAllItems()
        let status=NSMenuItem(title:controller.status,action:nil,keyEquivalent:"");status.isEnabled=false;menu.addItem(status)
        for (title,action) in [(controller.armed ? "暂停并释放按键":"启用映射",#selector(toggleMapping)),("打开 tourXbox",#selector(openMain)),("退出 tourXbox",#selector(quitApp))]{
            let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;menu.addItem(item)
        }
    }
    @objc private func toggleMapping(){controller?.toggleRunning()}
    @objc private func openMain(){controller?.showMainWindow()}
    @objc private func quitApp(){controller?.stop("退出");NSApp.terminate(nil)}
    static private(set) var iconLoaded=false
    static private(set) var iconSource="unavailable"
    func applicationDidFinishLaunching(_ notification:Notification){
        NSApp.setActivationPolicy(.regular)
        for name in ["AppIcon","tourXbox"] {
            if let url=Bundle.main.url(forResource:name,withExtension:"icns"),let icon=NSImage(contentsOf:url),icon.isValid {
                NSApp.dockTile.display()
                Self.iconLoaded=true;Self.iconSource="AppIcon.icon (system rendered)"
                break
            }
        }
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {
        sender.windows.first{!($0 is NSPanel) && $0.canBecomeMain}?.makeKeyAndOrderFront(nil)
        return true
    }
}
private struct WorkspaceWindowReader:NSViewRepresentable {
    var register:(NSWindow)->Void
    final class Reader:NSView {
        var register:((NSWindow)->Void)?
        override func hitTest(_ point:NSPoint)->NSView?{nil}
        override func viewDidMoveToWindow(){super.viewDidMoveToWindow();if let window{register?(window)}}
    }
    func makeNSView(context:Context)->Reader{let view=Reader();view.register=register;return view}
    func updateNSView(_ view:Reader,context:Context){view.register=register;if let window=view.window{register(window)}}
}

struct FloatingActionStyle:ViewModifier {
    @ViewBuilder func body(content:Content)->some View {
        if #available(macOS 26.0,*) {content.buttonStyle(.glass)}
        else {content.buttonStyle(.bordered)}
    }
}
