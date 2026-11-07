import SwiftUI
#if DEBUG
import Combine
#endif
import AppKit
#if canImport(MappingCore)
import MappingCore
#endif

enum PaletteMode:String,Codable,CaseIterable {case wheel,luma}
struct PalettePreferences:Codable,Equatable {
    var size=1.0
    var position=2
    var holdToShow=true
    var follow=true
    var wheelHSL=false
    var focused=true
    var defaultMode=PaletteMode.wheel
    var precision=0.2
}
@MainActor final class PalettePresentation:ObservableObject {
    @Published var mode:PaletteMode
    @Published var pinned=false
    @Published var preview=false
    #if DEBUG
    private var debugTrace:AnyCancellable?
    #endif
    init(_ mode:PaletteMode){self.mode=mode
        #if DEBUG
        debugTrace=RuntimeTrace.observe(objectWillChange,name:"PalettePresentation")
        #endif
    }
}
@MainActor final class PaletteModel:ObservableObject {
    @Published var color=PaletteRGB.hsv(0.52,0.45,0.65)
    @Published var original=PaletteRGB.hsv(0.52,0.45,0.65)
    @Published var hue=0.52
    @Published var labL=60.0
    @Published var labA=0.0
    @Published var labB=0.0
    @Published var comparing=false
    @Published var preferences:PalettePreferences
    let bridge=PhotoshopColorBridge()
    var changed:(()->Void)?
    var acceptsHostReads=true
    #if DEBUG
    private var debugTrace:AnyCancellable?
    #endif
    var lightRange:ClosedRange<Double> {
        guard preferences.focused else{return 0...100}
        let center=original.lab.l
        return max(0,center-20)...min(100,center+20)
    }
    init(){
        preferences=UserDefaults.standard.data(forKey:"palette.preferences.v1").flatMap{try? JSONDecoder().decode(PalettePreferences.self,from:$0)} ?? PalettePreferences()
        receive(color)
        #if DEBUG
        debugTrace=RuntimeTrace.observe(objectWillChange,name:"PaletteModel")
        #endif
        bridge.onRead={ [weak self] rgb in
            guard let self,self.acceptsHostReads else{return}
            self.original=rgb;self.receive(rgb)
        }
    }
    func save(){
        guard let data=try? JSONEncoder().encode(preferences) else{return}
        DispatchQueue.main.async{[weak self] in
            UserDefaults.standard.set(data,forKey:"palette.preferences.v1");self?.changed?()
        }
    }
    func receive(_ c:PaletteRGB){color=c.clipped;let hsv=color.hsv;if hsv.s>0.0001{hue=hsv.h};let lab=color.lab;labL=lab.l;labA=lab.a;labB=lab.b}
    func select(_ c:PaletteRGB){receive(c);bridge.submit(color)}
    func selectLab(l:Double,a:Double,b:Double){
        let c=PaletteRGB.lab(l,a,b)
        guard !preferences.focused || c.inGamut else{return}
        color=c.clipped;labL=l;labA=a;labB=b
        if color.hsv.s>0.0001{hue=color.hsv.h};bridge.submit(color)
    }
    func setHue(_ value:Double){
        hue=PaletteRGB.wrap(value)
        if preferences.wheelHSL {let c=color.hsl;select(.hsl(hue,c.s,c.l))}
        else {let c=color.hsv;select(.hsv(hue,c.s,c.v))}
    }
    func turn(_ radians:Double,mode:PaletteMode,fine:Bool){
        guard radians != 0 else{return}
        let amount=radians/(2*Double.pi)*(fine ? preferences.precision:1)
        if mode == .wheel {setHue(hue+amount)}
        else {let range=lightRange;let l=min(range.upperBound,max(range.lowerBound,labL+amount*(range.upperBound-range.lowerBound)));selectLab(l:l,a:labA,b:labB)}
    }
    func adjustPlane(x:Double,y:Double,mode:PaletteMode){
        if mode == .luma {selectLab(l:labL,a:labA+x*2,b:labB+y*2)}
        else if preferences.wheelHSL {let c=color.hsl;select(.hsl(hue,c.s+x*0.01,c.l+y*0.01))}
        else {let c=color.hsv;select(.hsv(hue,c.s+x*0.01,c.v+y*0.01))}
    }
}

/// Raster fields are cached at logical resolution; no per-frame GPU readback, screen
/// capture, or recomputation of the controller artwork. Small bounded LRU storage.
private enum PaletteRaster {
    private static let cache=NSCache<NSString,NSImage>()
    static func image(_ key:String,width:Int,height:Int,pixel:(Double,Double)->PaletteRGB?)->NSImage {
        cache.countLimit=20
        if let value=cache.object(forKey:key as NSString){return value}
        var bytes=[UInt8](repeating:0,count:width*height*4)
        for y in 0..<height {for x in 0..<width {
            let p=pixel(Double(x)/Double(max(1,width-1)),Double(y)/Double(max(1,height-1)))
            let c=(p ?? PaletteRGB(0.6,0.6,0.6)).clipped,i=(y*width+x)*4
            bytes[i]=UInt8((c.r*255).rounded());bytes[i+1]=UInt8((c.g*255).rounded());bytes[i+2]=UInt8((c.b*255).rounded());bytes[i+3]=255
        }}
        let data=Data(bytes),provider=CGDataProvider(data:data as CFData)!
        let cg=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.relativeColorimetric)!
        let result=NSImage(cgImage:cg,size:NSSize(width:width,height:height));cache.setObject(result,forKey:key as NSString);return result
    }
    static var ring:NSImage {image("hue-ring",width:360,height:360){x,y in
        let h=PaletteRGB.wrap(atan2(y-0.5,x-0.5)/(2*Double.pi)+5.0/12)
        return .hsv(h,1,1)
    }}
    static func square(_ hue:Double)->NSImage {
        let h=(hue*720).rounded()/720
        return image("sv-\(h)",width:180,height:180){x,y in .hsv(h,x,1-y)}
    }
    static func triangle(_ hue:Double)->NSImage {
        let h=(hue*720).rounded()/720
        return image("triangle-\(h)",width:180,height:180){x,y in let p=PaletteRGB.triangle(x,y);return .hsl(h,p.s,p.l)}
    }
    static func luma(_ light:Double,focused:Bool)->NSImage {
        let l=(light*2).rounded()/2
        return image("lab-\(l)-\(focused)",width:270,height:270){x,y in
            let c=PaletteRGB.lab(l,(x-0.5)*256,(0.5-y)*256)
            return focused && !c.inGamut ? nil:c
        }
    }
    static func lightBar(a:Double,b:Double,focused:Bool,range:ClosedRange<Double>)->NSImage {
        let a=a.rounded(),b=b.rounded()
        return image("light-\(a)-\(b)-\(focused)-\(range.lowerBound)-\(range.upperBound)",width:270,height:18){x,_ in
            let c=PaletteRGB.lab(range.lowerBound+x*(range.upperBound-range.lowerBound),a,b);return focused && !c.inGamut ? nil:c
        }
    }
}
private struct HueRing:View {
    @ObservedObject var model:PaletteModel
    var body:some View {
        ZStack {
            Image(nsImage:PaletteRaster.ring).resizable().mask(Circle().stroke(lineWidth:22).padding(11))
            RoundedRectangle(cornerRadius:3).stroke(.black.opacity(0.75),lineWidth:4)
                .overlay(RoundedRectangle(cornerRadius:3).stroke(.white,lineWidth:2))
                .frame(width:14,height:22).offset(y:-124).rotationEffect(.degrees((model.hue-1.0/6)*360))
        }.frame(width:270,height:270).contentShape(Circle())
            .gesture(DragGesture(minimumDistance:0).onChanged {g in
                let p=g.location,r=hypot(p.x-135,p.y-135)
                guard r>100 else{return}
                model.setHue(atan2(p.y-135,p.x-135)/(2*Double.pi)+5.0/12)
            })
    }
}
private struct HSLTriangle:Shape {
    func path(in r:CGRect)->Path {Path{p in p.move(to:CGPoint(x:r.minX,y:r.minY));p.addLine(to:CGPoint(x:r.maxX,y:r.midY));p.addLine(to:CGPoint(x:r.minX,y:r.maxY));p.closeSubpath()}}
}
private struct SelectionDot:View {
    var color:PaletteRGB
    var body:some View {Circle().fill(Color(red:color.r,green:color.g,blue:color.b)).overlay(Circle().stroke(.black.opacity(0.7),lineWidth:3)).overlay(Circle().stroke(.white,lineWidth:1.5)).frame(width:12,height:12).allowsHitTesting(false)}
}
private struct PalettePlane:View {
    @ObservedObject var model:PaletteModel
    @ObservedObject var presentation:PalettePresentation
    @State private var dragPoint:CGPoint?
    private let geometry=PaletteWheelGeometry(diameter:270,ringWidth:22,contentInset:8)
    var body:some View {
        field.overlay(alignment:.topLeading){if model.comparing,let p=dragPoint {
            HStack(spacing:0){Color(red:model.original.r,green:model.original.g,blue:model.original.b);Color(red:model.color.r,green:model.color.g,blue:model.color.b)}
                .frame(width:38,height:38).clipShape(Circle()).overlay(Circle().stroke(.white,lineWidth:1.5))
                .shadow(color:.black.opacity(0.3),radius:4,y:2)
                .offset(x:min(232,max(0,p.x-19)),y:min(232,max(0,p.y-48))).allowsHitTesting(false)
        }}.simultaneousGesture(DragGesture(minimumDistance:0).onChanged{g in dragPoint=g.location;model.comparing=true}.onEnded{_ in model.comparing=false;dragPoint=nil})
    }
    @ViewBuilder private var field:some View {
        if presentation.mode == .wheel {
            ZStack {
                HueRing(model:model)
                if model.preferences.wheelHSL {
                    let p=PaletteRGB.trianglePoint(s:model.color.hsl.s,l:model.color.hsl.l)
                    let radius=geometry.innerRadius,width=geometry.triangleWidth,height=geometry.triangleHeight
                    Image(nsImage:PaletteRaster.triangle(model.hue)).resizable().frame(width:width,height:height).clipShape(HSLTriangle())
                        .overlay(alignment:.topLeading){SelectionDot(color:model.color).offset(x:p.x*width-6,y:p.y*height-6)}
                        .contentShape(HSLTriangle()).gesture(DragGesture(minimumDistance:0).onChanged{g in
                            let p=PaletteRGB.triangle(g.location.x/width,g.location.y/height)
                            model.select(.hsl(model.hue,p.s,p.l))
                        }).offset(x:radius/4)
                } else {
                    let side=geometry.squareSide
                    Image(nsImage:PaletteRaster.square(model.hue)).resizable().frame(width:side,height:side)
                        .overlay(alignment:.topLeading){SelectionDot(color:model.color).offset(x:model.color.hsv.s*side-6,y:(1-model.color.hsv.v)*side-6)}
                        .contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged{g in model.select(.hsv(model.hue,PaletteRGB.clamp(g.location.x/side),1-PaletteRGB.clamp(g.location.y/side)))})
                }
            }.frame(width:270,height:270)
        } else {
            Image(nsImage:PaletteRaster.luma(model.labL,focused:model.preferences.focused)).resizable()
                .frame(width:270,height:270)
                .overlay(alignment:.topLeading){SelectionDot(color:model.color).offset(x:(model.labA/256+0.5)*270-6,y:(0.5-model.labB/256)*270-6)}
                .contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged{g in
                    model.selectLab(l:model.labL,a:(PaletteRGB.clamp(g.location.x/270)-0.5)*256,b:(0.5-PaletteRGB.clamp(g.location.y/270))*256)
                })
        }
    }
}
private struct LumaSymbol:Shape {
    func path(in r:CGRect)->Path {Path{p in
        p.move(to:CGPoint(x:r.minX,y:r.height*0.64));p.addCurve(to:CGPoint(x:r.width*0.48,y:r.height*0.55),control1:CGPoint(x:r.width*0.15,y:r.height*0.45),control2:CGPoint(x:r.width*0.32,y:r.height*0.85));p.addCurve(to:CGPoint(x:r.maxX,y:r.height*0.65),control1:CGPoint(x:r.width*0.63,y:r.height*0.1),control2:CGPoint(x:r.width*0.74,y:r.height*0.34))
        p.move(to:CGPoint(x:r.minX,y:r.height*0.88));p.addQuadCurve(to:CGPoint(x:r.maxX,y:r.height*0.9),control:CGPoint(x:r.width*0.5,y:r.height*1.1))
    }}
}
private struct PaletteDragHandle:NSViewRepresentable {
    final class Handle:NSView {override func mouseDown(with event:NSEvent){window?.performDrag(with:event)}}
    func makeNSView(context:Context)->Handle{Handle()}
    func updateNSView(_ view:Handle,context:Context){}
}
/// Transparent geometry anchors only. All appearance and interaction is SwiftUI.
private struct PaletteControlAnchor:NSViewRepresentable {
    var title:String
    var register:(NSView)->Void = {_ in}
    final class Anchor:NSView {override func hitTest(_ point:NSPoint)->NSView?{nil}}
    func makeNSView(context:Context)->Anchor{Anchor()}
    func updateNSView(_ view:Anchor,context:Context){
        view.identifier=NSUserInterfaceItemIdentifier("palette."+title)
        if title == "调色盘设置"{DispatchQueue.main.async{register(view)}}
    }
}
private struct PaletteGlassGroup<Content:View>:View {
    @ViewBuilder var content:()->Content
    @ViewBuilder var body:some View {
        if #available(macOS 26.0,*) {GlassEffectContainer(spacing:8,content:content)}
        else {content()}
    }
}
private enum PalettePanelLayout {
    static func height(size:Double,mode:PaletteMode)->Double {270*size+(mode == .luma ? 154:116)}
}
struct DynamicPaletteView:View {
    @ObservedObject var model:PaletteModel
    @ObservedObject var presentation:PalettePresentation
    var pin:()->Void = {}
    var settings:(NSView)->Void = {_ in}
    var interact:()->Void = {}
    var layoutChanged:()->Void = {}
    var close:()->Void = {}
    var snapshot=false
    @State private var gearAnchor:NSView?
    private var fieldSide:Double {270*model.preferences.size}
    private var panelWidth:Double {fieldSide+32}
    private func control(_ symbol:String,_ title:String,selected:Bool=false,action:@escaping()->Void)->some View {
        Button{interact();action()}label:{Label(title,systemImage:symbol).labelStyle(.iconOnly)}
            .modifier(FloatingActionStyle()).buttonBorderShape(.circle).controlSize(.regular)
            .tint(selected ? Color.accentColor:nil)
            .help(title).accessibilityLabel(title).accessibilityValue(selected ? "已选择":"未选择")
            .background(PaletteControlAnchor(title:title){view in if title == "调色盘设置",gearAnchor !== view{gearAnchor=view}})
    }
    var body:some View {
        VStack(spacing:0) {
            PaletteGlassGroup {
                HStack(spacing:12) {
                    control("circle.circle","色轮",selected:presentation.mode == .wheel){presentation.mode = .wheel}
                    control("square.stack.3d.up","同明度",selected:presentation.mode == .luma){presentation.mode = .luma}
                    PaletteDragHandle().frame(maxWidth:.infinity).accessibilityHidden(true)
                    control(presentation.pinned ? "pin.fill":"pin","固定调色盘",selected:presentation.pinned,action:pin)
                    if presentation.preview {control("xmark","关闭预览",action:close)}
                }
            }.padding(.horizontal,16).frame(height:44)
            Color.clear.frame(height:12)
            PalettePlane(model:model,presentation:presentation).frame(width:270,height:270)
                .scaleEffect(model.preferences.size).frame(width:fieldSide,height:fieldSide)
            Color.clear.frame(height:12)
            if presentation.mode == .luma {
                lightness.frame(width:fieldSide,height:26)
                Color.clear.frame(height:12)
            }
            PaletteGlassGroup {
                HStack(spacing:12) {
                    Button{interact();model.select(model.original)}label:{
                        HStack(spacing:0){Color(red:model.original.r,green:model.original.g,blue:model.original.b);Color(red:model.color.r,green:model.color.g,blue:model.color.b)}
                            .frame(width:36,height:22).clipShape(RoundedRectangle(cornerRadius:4))
                    }.buttonStyle(.plain).help("恢复原色").accessibilityLabel("恢复原色")
                    Spacer(minLength:0)
                    Picker("调色盘子模式",selection:Binding(get:{submodeSelected},set:{value in
                        interact();if presentation.mode == .wheel{model.preferences.wheelHSL=value}else{model.preferences.focused=value};model.save()
                    })) {
                        Text(submodeLabels[0]).tag(false)
                        Text(submodeLabels[1]).tag(true)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    control("gearshape","调色盘设置") {if let gearAnchor {settings(gearAnchor)}}
                }
            }.padding(.horizontal,16).frame(height:36)
            Color.clear.frame(height:12)
        }
        .frame(width:panelWidth,height:PalettePanelLayout.height(size:model.preferences.size,mode:presentation.mode))
        .background(Color(nsColor:.windowBackgroundColor),in:RoundedRectangle(cornerRadius:16))
        .preferredColorScheme(.dark)
        .onChange(of:presentation.mode){DispatchQueue.main.async{layoutChanged()}}
    }
    private var submodeLabels:[String]{presentation.mode == .wheel ? ["HSV","HSL"]:["完整","聚焦"]}
    private var submodeSelected:Bool{presentation.mode == .wheel ? model.preferences.wheelHSL:model.preferences.focused}
    private var lightness:some View {
        let range=model.lightRange,span=range.upperBound-range.lowerBound
        return Image(nsImage:PaletteRaster.lightBar(a:model.labA,b:model.labB,focused:model.preferences.focused,range:range)).resizable()
            .clipShape(RoundedRectangle(cornerRadius:5))
            .overlay(alignment:.leading){Capsule().stroke(.black.opacity(0.7),lineWidth:3).overlay(Capsule().stroke(.white,lineWidth:1.5))
                .frame(width:8,height:26).offset(x:PaletteRGB.clamp((model.labL-range.lowerBound)/span)*(fieldSide-8))}
            .contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged{g in interact();model.selectLab(l:range.lowerBound+PaletteRGB.clamp(g.location.x/fieldSide)*span,a:model.labA,b:model.labB)})
            .accessibilityLabel("明度")
    }
}

private final class PalettePanel:NSPanel {
    var dismiss:(()->Void)?
    override func cancelOperation(_ sender:Any?){dismiss?()}
    override func keyDown(with event:NSEvent){if event.keyCode == 53{dismiss?()}else{super.keyDown(with:event)}}
    override var canBecomeKey:Bool{true}
    override var canBecomeMain:Bool{false}
}
private final class PaletteHostingView:NSHostingView<DynamicPaletteView> {
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
}
@MainActor final class DynamicPaletteCoordinator:ObservableObject {
    let model=PaletteModel()
    @Published private(set) var visible=false
    private var temporary:(PalettePanel,PalettePresentation)?
    private var pinned:(PalettePanel,PalettePresentation)?
    var openSettings:(()->Void)?
    private var preferencesPopover:NSPopover?
    private(set) var nativeClicks=0
    private var observers:[NSObjectProtocol]=[]
    private var samplingMonitor:Any?
    private var timer:Timer?
    private var held=false
    private var preview=false
    var isPreview:Bool{preview}
    private var previous:Set<PadControl>=[]
    private var suppressed:Set<PadControl>=[]
    private var invoker:PadControl?
    // Once the pen enters, keep the session in editing mode until release.
    // Edge noise must not alternate Option down/up or resume host reads.
    private var editing=false
    var isEditing:Bool {editing && visible}
    private var left=StickDialPrototype()
    private var right=StickDialPrototype()
    private var lastPoint=CGPoint.zero
    private var lastRead=0.0
    private(set) var rotationEvents=0
    private(set) var rotationRadians=0.0
    var activeMode:String {active?.1.mode.rawValue ?? "closed"}
    var pointerInside:Bool {[temporary,pinned].compactMap{$0}.contains{$0.0.frame.contains(NSEvent.mouseLocation)}}
    var sampling:((Bool)->Void)?
    var onCancel:(()->Void)?
    var controlFrames:[[String:Any]] {
        [temporary,pinned].compactMap{$0}.flatMap{pair -> [[String:Any]] in
            guard let root=pair.0.contentView else{return []}
            var result:[[String:Any]]=[]
            @MainActor func visit(_ view:NSView){
                if let id=view.identifier?.rawValue,id.hasPrefix("palette.") {
                    let frame=view.convert(view.bounds,to:root)
                    result.append(["control":id,"x":frame.minX,"y":frame.minY,"width":frame.width,"height":frame.height,"enabled":true])
                }
                for child in view.subviews{visit(child)}
            }
            visit(root);return result
        }
    }
    var captures:Set<PadControl> {visible ? Set([.a,.b,.x,.y,.view,.l3,.r3,.lt,.rt,.up,.down,.left,.right,.stickLeft,.stickRight,.stickUp,.stickDown,.rightStickLeft,.rightStickRight,.rightStickUp,.rightStickDown]).union(invoker.map{[$0]} ?? []):suppressed}
    init(){
        model.changed={ [weak self] in self?.resize() }
        model.bridge.onFailure={ [weak self] in self?.sampling?(false) }
        samplingMonitor=NSEvent.addGlobalMonitorForEvents(matching:.leftMouseUp){[weak self] _ in
            Task{@MainActor in
                guard let self,self.visible,self.held,!self.editing else{return}
                self.model.bridge.read()
            }
        }
    }
    func showPreview(){
        if preview && visible {cancel();return}
        preview=true;show(at:NSEvent.mouseLocation,mode:model.preferences.defaultMode);held=false
        temporary?.0.makeKeyAndOrderFront(nil)
    }
    private var active:(PalettePanel,PalettePresentation)? {
        if let t=temporary,t.0.frame.contains(NSEvent.mouseLocation){return t}
        if let p=pinned,p.0.frame.contains(NSEvent.mouseLocation){return p}
        return temporary ?? pinned
    }
    private func make(_ mode:PaletteMode)->(PalettePanel,PalettePresentation){
        let presentation=PalettePresentation(mode)
        let panel=PalettePanel(contentRect:NSRect(x:0,y:0,width:300,height:444),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.title="动态调色盘"
        panel.dismiss={ [weak self] in self?.cancel() }
        panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true;panel.level = .floating;panel.hidesOnDeactivate=false;panel.isReleasedWhenClosed=false
        panel.appearance=NSAppearance(named:.darkAqua);panel.becomesKeyOnlyIfNeeded=true;panel.worksWhenModal=true
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        panel.contentView=PaletteHostingView(rootView:DynamicPaletteView(model:model,presentation:presentation,
            pin:{[weak self,weak presentation] in if let presentation{self?.togglePin(presentation)}},
            settings:{[weak self] anchor in self?.openPreferences(anchor)},
            interact:{[weak self] in self?.beginEditing()},layoutChanged:{[weak self] in self?.resize()},close:{[weak self] in self?.cancel()}))
        return(panel,presentation)
    }
    private func show(at point:CGPoint,mode:PaletteMode){
        if temporary==nil {temporary=make(mode)}
        if let t=temporary {
            t.1.preview=preview
            let anchor=model.preferences.follow ? point : (NSScreen.main.map{CGPoint(x:$0.visibleFrame.midX,y:$0.visibleFrame.midY)} ?? point)
            place(t.0,at:anchor);t.0.orderFrontRegardless()
        }
        visible=true;startTimer()
    }
    private func place(_ panel:PalettePanel,at point:CGPoint){
        let mode=[temporary,pinned].compactMap{$0}.first{$0.0 === panel}?.1.mode ?? model.preferences.defaultMode
        let w=270*model.preferences.size+32,h=PalettePanelLayout.height(size:model.preferences.size,mode:mode)
        let screen=NSScreen.screens.first{$0.frame.contains(point)} ?? NSScreen.main
        let f=screen?.visibleFrame ?? CGRect(x:0,y:0,width:1440,height:900),pos=model.preferences.position
        let col=pos%3,row=pos/3
        var x=point.x+(col==0 ? -w-18:col==2 ? 18:-w/2)
        var y=point.y+(row==0 ? 18:row==2 ? -h-18:-h/2)
        x=min(max(f.minX+6,x),max(f.minX+6,f.maxX-w-6));y=min(max(f.minY+6,y),max(f.minY+6,f.maxY-h-6))
        panel.setFrame(CGRect(x:x,y:y,width:w,height:h),display:true)
        lastPoint=point
    }
    private func resize(){
        let width=270*model.preferences.size+32
        for pair in [temporary,pinned].compactMap({$0}) {
            let height=PalettePanelLayout.height(size:model.preferences.size,mode:pair.1.mode)
            let panel=pair.0,visible=panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
            let x=min(max(visible.minX,panel.frame.minX),max(visible.minX,visible.maxX-width))
            let y=min(max(visible.minY,panel.frame.maxY-height),max(visible.minY,visible.maxY-height))
            panel.setFrame(NSRect(x:x,y:y,width:width,height:height),display:true)
        }
    }
    private func togglePin(_ p:PalettePresentation){
        if p.pinned {p.pinned=false;pinned?.0.orderOut(nil);pinned=nil;visible=temporary != nil}
        else if let t=temporary,t.1===p {pinned?.0.orderOut(nil);p.pinned=true;pinned=t;temporary=nil}
        if !visible {stopTimer()}
    }
    func cancel(){
        sampling?(false);held=false;temporary?.0.orderOut(nil);pinned?.0.orderOut(nil);temporary=nil;pinned=nil;visible=false;preview=false;invoker=nil
        left.reset();right.reset();model.bridge.invalidate();preferencesPopover?.close();preferencesPopover=nil;stopTimer()
    }
    func process(values:[(PadControl,Bool)],lx:Float,ly:Float,rx:Float,ry:Float,allowed:Bool,invokers:Set<PadControl>){
        let current=Set(values.filter{$0.1}.map{$0.0}),downs=current.subtracting(previous),ups=previous.subtracting(current)
        let panelDowns=downs.subtracting(invokers)
        defer{previous=current;suppressed.formIntersection(current)}
        guard allowed else {if !preview && visible {cancel()};return}
        if let opener=downs.first(where:{invokers.contains($0)}) {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.adobe.Photoshop" else{return}
            if !model.preferences.holdToShow,temporary != nil {finish();return}
            invoker=opener;held=true;preview=false;editing=false;model.acceptsHostReads=true;left.reset();right.reset()
            model.bridge.enabled=true;model.bridge.read()
            show(at:NSEvent.mouseLocation,mode:model.preferences.defaultMode)
        }
        if let invoker,ups.contains(invoker) {held=false;sampling?(false);if model.preferences.holdToShow {finish()}}
        guard let pair=active else{return}
        let onPanel=pair.0.frame.contains(NSEvent.mouseLocation)
        let time=ProcessInfo.processInfo.systemUptime
        let l=left.update(x:Double(lx),y:Double(ly),time:time)
        let r=right.update(x:Double(rx),y:Double(ry),time:time)
        // Deliberate rotary input also enters editing. A small panel or a pen
        // hovering just outside it must not silently discard every stick packet.
        if onPanel || l.radians != 0 || r.radians != 0 {editing=true;if model.bridge.connected {model.acceptsHostReads=false}}
        sampling?(held && !editing && model.bridge.connected)
        if panelDowns.contains(.b) {suppressed.formUnion(current);cancel();return}
        if panelDowns.contains(.a) {suppressed.formUnion(current);finish();return}
        guard editing else{return}
        if panelDowns.contains(.x) {pair.1.mode = pair.1.mode == .wheel ? .luma:.wheel}
        if panelDowns.contains(.y) {if pair.1.mode == .wheel {model.preferences.wheelHSL.toggle()}else{model.preferences.focused.toggle()};model.save()}
        if panelDowns.contains(.view){togglePin(pair.1)}
        if l.radians != 0 {rotationEvents += 1;rotationRadians += l.radians}
        model.turn(l.radians,mode:pair.1.mode,fine:current.contains(invoker == .lt ? .rt:.lt))
        // Second rotary input is an explicitly documented Xbox extension, not an
        // unverified claim about TourBox's Scroll/Dial default bindings.
        if r.steps != 0 {model.adjustPlane(x:Double(r.steps),y:0,mode:pair.1.mode)}
        if panelDowns.contains(.up){model.adjustPlane(x:0,y:1,mode:pair.1.mode)}
        if panelDowns.contains(.down){model.adjustPlane(x:0,y:-1,mode:pair.1.mode)}
    }
    private func finish(){
        sampling?(false);suppressed.formUnion(previous);held=false;temporary?.0.orderOut(nil);temporary=nil;visible=pinned != nil;left.reset();right.reset()
        if !visible {stopTimer()}
    }
    private func startTimer(){
        guard timer==nil else{return}
        let value=Timer(timeInterval:1.0/30,repeats:true){[weak self] _ in Task{@MainActor in self?.tick()}}
        value.tolerance=0.005
        timer=value;RunLoop.main.add(value,forMode:.common)
    }
    private func stopTimer(){timer?.invalidate();timer=nil}
    private func tick(){
        guard visible else{stopTimer();return}
        if !preview,NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.adobe.Photoshop" {cancel();return}
        let point=NSEvent.mouseLocation,onPanel=[temporary,pinned].compactMap{$0}.contains{$0.0.frame.contains(point)}
        if onPanel {editing=true;if model.bridge.connected {model.acceptsHostReads=false}}
        sampling?(held && !editing && model.bridge.connected)
        // Near-pen placement happens once at invocation. Chasing the pen made
        // entry impossible and repeatedly crossed the Option sampling boundary.
        // No repeated Photoshop scripts while holding. Even read-only scripts
        // can flash Photoshop's contextual/progress UI and disrupt pen input.
        // Read once when opening; deliberate selection supplies later writes.
    }
    private func openPreferences(_ anchor:NSView){
        guard anchor.window != nil else{return}
        beginEditing()
        if preferencesPopover?.isShown == true {preferencesPopover?.close();return}
        let popover=NSPopover();popover.behavior = .transient
        let host=NSHostingController(rootView:PaletteQuickSettings(model:model,more:{[weak self] in self?.openSettings?()}))
        popover.contentViewController=host;host.view.layoutSubtreeIfNeeded()
        popover.contentSize=host.view.fittingSize
        popover.show(relativeTo:anchor.bounds,of:anchor,preferredEdge:.maxX)
        preferencesPopover=popover
    }
    private func beginEditing(){
        nativeClicks += 1;editing=true;sampling?(false)
        if model.bridge.connected{model.acceptsHostReads=false}
    }
    func snapshots(to directory:URL){
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for name in ["HSV","HSL","Luma-Full","Luma-Focused"] {
            model.preferences.wheelHSL=name=="HSL";model.preferences.focused=name=="Luma-Focused"
            model.receive(name.hasPrefix("Luma") ? PaletteRGB(0.19,0.55,0.63):PaletteRGB.hsv(0.25,0.8,0.85))
            let p=PalettePresentation(name.hasPrefix("Luma") ? .luma:.wheel)
            let renderer=ImageRenderer(content:DynamicPaletteView(model:model,presentation:p,snapshot:true));renderer.scale=2
            if let cg=renderer.cgImage {let rep=NSBitmapImageRep(cgImage:cg);if let data=rep.representation(using:.png,properties:[:]) {try? data.write(to:directory.appendingPathComponent(name+".png"))}}
        }
    }
}

struct PalettePreferencesView:View {
    @ObservedObject var coordinator:DynamicPaletteCoordinator
    var controller:ControllerModel?
    @ObservedObject private var model:PaletteModel
    @ObservedObject private var bridge:PhotoshopColorBridge
    init(coordinator:DynamicPaletteCoordinator,controller:ControllerModel?=nil){self.coordinator=coordinator;self.controller=controller;model=coordinator.model;bridge=coordinator.model.bridge}
    var body:some View {
        Form {
            if let controller {
                Section("呼出按键"){
                    LabeledContent("当前配置"){HStack{ControllerButtonGlyph(control:controller.paletteBinding.control,nativeName:controller.inputGlyphs[controller.paletteBinding.control]);Text(controller.paletteBinding.gesture.title)}}
                    Button("编辑呼出按键…"){controller.selected=controller.paletteBinding.control;controller.selectedBindingID=controller.paletteBinding.id;controller.settingsSection = .mapping}
                }
            }
            Section("面板外观") {
                Picker("默认模式",selection:$model.preferences.defaultMode){Text("色轮").tag(PaletteMode.wheel);Text("同明度").tag(PaletteMode.luma)}
                HStack(alignment:.top){
                    Text("色轮样式");Spacer(minLength:12)
                    HStack(spacing:12){styleChoice(hsl:false);styleChoice(hsl:true)}
                }.accessibilityElement(children:.contain)
                HStack(alignment:.top){
                    Text("同明度范围");Spacer(minLength:12)
                    HStack(spacing:12){lumaChoice(focused:false);lumaChoice(focused:true)}
                }.accessibilityElement(children:.contain)
                Picker("尺寸",selection:$model.preferences.size){Text("小").tag(0.85);Text("中").tag(1.0);Text("大").tag(1.2)}
            }
            Section {
                Toggle("在笔尖附近呼出",isOn:$model.preferences.follow)
                if model.preferences.follow {Picker("方位",selection:$model.preferences.position){ForEach(0..<9){i in Text(["左上","上方","右上","左侧","居中","右侧","左下","下方","右下"][i]).tag(i)}}}
                Button(coordinator.isPreview && coordinator.visible ? "关闭预览":"预览调色盘"){coordinator.showPreview()}
            } header:{Text("显示位置")} footer:{Text("每次呼出定位一次，选色过程中保持不动；图钉可固定另一面板。")}
            Section("手柄操作") {
                LabeledContent{Text("色相／明度")}label:{HStack{controls([.l3]);Image(systemName:"arrow.clockwise")}}
                LabeledContent{Text("横向微调")}label:{HStack{controls([.r3]);Image(systemName:"arrow.clockwise")}}
                LabeledContent{Text("主模式／子模式")}label:{controls([.x,.y])}
                LabeledContent{Text("固定／完成／关闭")}label:{controls([.view,.a,.b])}
                LabeledContent{Text("纵向微调")}label:{controls([.up,.down])}
                LabeledContent("精细调整"){controls([controller?.paletteBinding.control == .lt ? .rt:.lt])}
            }
            Section {
                LabeledContent("状态",value:bridge.status)
                Button("连接并读取前景色"){bridge.enabled=true;bridge.read(allowWhileConfiguring:true)}
            } header:{Text("Photoshop")} footer:{Text("当前支持 RGB 文档。采样结束后更新颜色，不持续轮询；同明度使用 CIELAB 近似算法，尚未复现官方私有 Luma 算法。")}
        }.formStyle(.grouped).onChange(of:model.preferences){model.save()}
    }
    private func controls(_ values:[PadControl])->some View {
        HStack(spacing:6){ForEach(values){control in ControllerButtonGlyph(control:control,nativeName:controller?.inputGlyphs[control])}}
            .accessibilityElement(children:.ignore).accessibilityLabel(values.map(\.title).joined(separator:"、"))
    }
    private func lumaChoice(focused:Bool)->some View {
        appearanceChoice(focused ? "聚焦":"完整",selected:model.preferences.focused == focused,
                         action:{model.preferences.focused=focused}) {
            Image(nsImage:PaletteRaster.luma(60,focused:focused)).resizable()
                .clipShape(RoundedRectangle(cornerRadius:3))
        }
    }
    private func styleChoice(hsl:Bool)->some View {
        appearanceChoice(hsl ? "HSL 三角形":"HSV 方形",selected:model.preferences.wheelHSL == hsl,
                         action:{model.preferences.wheelHSL=hsl}) {PaletteStyleExample(hsl:hsl)}
    }
    private func appearanceChoice<Thumbnail:View>(_ title:String,selected:Bool,action:@escaping()->Void,
                                                  @ViewBuilder thumbnail:()->Thumbnail)->some View {
        Button(action:action){
            VStack(spacing:6){
                thumbnail().frame(width:56,height:56).accessibilityHidden(true)
                Text(title).font(.caption).lineLimit(1)
            }.padding(4).frame(width:96,height:88)
        }.buttonStyle(.bordered)
            .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(selected ? Color.accentColor:Color.clear,lineWidth:2).allowsHitTesting(false))
            .accessibilityLabel(title).accessibilityValue(selected ? "已选择":"未选择")
    }

}


private struct PaletteStyleExample:View {
    var hsl:Bool
    private let geometry=PaletteWheelGeometry(diameter:56,ringWidth:5,contentInset:3)
    var body:some View {
        ZStack {
            Image(nsImage:PaletteRaster.ring).resizable().frame(width:56,height:56).mask(Circle().strokeBorder(lineWidth:5))
            if hsl {
                Image(nsImage:PaletteRaster.triangle(0.52)).resizable().frame(width:geometry.triangleWidth,height:geometry.triangleHeight).clipShape(HSLTriangle()).offset(x:geometry.triangleCenterOffset)
            } else {
                Image(nsImage:PaletteRaster.square(0.52)).resizable().frame(width:geometry.squareSide,height:geometry.squareSide)
            }
        }.frame(width:56,height:56).accessibilityHidden(true)
    }
}

private struct PaletteQuickSettings:View {
    @ObservedObject var model:PaletteModel
    var more:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("调色盘外观").font(.headline)
            Grid(alignment:.leading,horizontalSpacing:16,verticalSpacing:12){
                GridRow{Text("尺寸");Picker("尺寸",selection:$model.preferences.size){Text("小").tag(0.85);Text("中").tag(1.0);Text("大").tag(1.2)}.labelsHidden().frame(width:150)}
                GridRow{Text("默认模式");Picker("默认模式",selection:$model.preferences.defaultMode){Text("色轮").tag(PaletteMode.wheel);Text("同明度").tag(PaletteMode.luma)}.labelsHidden().frame(width:150)}
            }.controlSize(.regular)
            Divider()
            Button("更多设置…",action:more)
        }.padding(16).frame(width:280).fixedSize(horizontal:false,vertical:true)
            .onChange(of:model.preferences){model.save()}
    }
}
