import Foundation

public enum PadControl: String, CaseIterable, Codable, Identifiable, Sendable {
    case lt, lb, rt, rb, l3, r3, view, menu, a, b, x, y
    case left, right, up, down, stickLeft, stickRight, stickUp, stickDown
    case home, share, rightStickLeft, rightStickRight, rightStickUp, rightStickDown
    case paddle1, paddle2, paddle3, paddle4
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .home: return "Xbox / Guide"
        case .share: return "Share"
        case .rightStickLeft: return "右摇杆 ←"; case .rightStickRight: return "右摇杆 →"
        case .rightStickUp: return "右摇杆 ↑"; case .rightStickDown: return "右摇杆 ↓"
        case .paddle1: return "P1（Elite）"; case .paddle2: return "P2（Elite）"
        case .paddle3: return "P3（Elite）"; case .paddle4: return "P4（Elite）"
        case .lt: return "LT"; case .lb: return "LB"; case .rt: return "RT"; case .rb: return "RB"
        case .l3: return "L3"; case .r3: return "R3"; case .view: return "View"; case .menu: return "Menu"
        case .a: return "A"; case .b: return "B"; case .x: return "X"; case .y: return "Y"
        case .left: return "十字 ←"; case .right: return "十字 →"; case .up: return "十字 ↑"; case .down: return "十字 ↓"
        case .stickLeft: return "左摇杆 ←"; case .stickRight: return "左摇杆 →"; case .stickUp: return "左摇杆 ↑"; case .stickDown: return "左摇杆 ↓"
        }
    }
}
public enum ActionMode: String, Codable, CaseIterable { case hold, tap, palette, stop, disabled }
public enum InputGesture:String,Codable,CaseIterable {case press,doubleTap,doubleHold}
public enum MappingScope: String, Codable, CaseIterable { case global, application }
public enum ShortcutEncoding:String,Codable,Sendable {case macOSVirtualKey,usbHID}
public struct Shortcut: Codable, Equatable {
    public var key: UInt16
    public var modifiers: [UInt16]
    public var encoding:ShortcutEncoding = .macOSVirtualKey
    public init(_ key: UInt16, _ modifiers: [UInt16] = []) { self.key = key; self.modifiers = modifiers }
    private enum CodingKeys:String,CodingKey {case key,modifiers,encoding}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        key=try c.decode(UInt16.self,forKey:.key);modifiers=try c.decode([UInt16].self,forKey:.modifiers)
        encoding=try c.decodeIfPresent(ShortcutEncoding.self,forKey:.encoding) ?? .macOSVirtualKey
    }
    public var keys: [UInt16] {
        var seen: Set<UInt16> = []
        return (modifiers + [key]).filter { seen.insert($0).inserted }
    }
    public static let modifierKeys: Set<UInt16> = [54,55,56,58,59,60,61,62]
}
public struct MappingBinding: Codable, Identifiable, Equatable {
    public var control: PadControl
    public var mode: ActionMode
    public var shortcut: Shortcut
    public var label: String
    public var gesture:InputGesture = .press
    public var companions:[PadControl] = []
    public var id: String { control.rawValue+":"+gesture.rawValue+":"+companions.map(\.rawValue).sorted().joined(separator:"+") }
    public init(_ control: PadControl, _ mode: ActionMode, _ shortcut: Shortcut = Shortcut(49), _ label: String = "") {
        self.control=control; self.mode=mode; self.shortcut=shortcut; self.label=label
    }
    private enum CodingKeys:String,CodingKey {case control,mode,shortcut,label,gesture,companions}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        control=try c.decode(PadControl.self,forKey:.control);mode=try c.decode(ActionMode.self,forKey:.mode)
        shortcut=try c.decode(Shortcut.self,forKey:.shortcut);label=try c.decode(String.self,forKey:.label)
        gesture=try c.decodeIfPresent(InputGesture.self,forKey:.gesture) ?? .press
        companions=try c.decodeIfPresent([PadControl].self,forKey:.companions) ?? []
    }
}
public struct Profile: Codable, Equatable {
    public var schemaVersion = 3
    public var scope: MappingScope = .global
    public var targetBundleID = "com.adobe.Photoshop"
    public var bridgePointerFlags = true
    public var bindings: [MappingBinding]
    public init(bindings: [MappingBinding]) { self.bindings=bindings }
    public static var drawing: Profile {
        var bindings = PadControl.allCases.map { MappingBinding($0, .disabled) }
        let active: [MappingBinding] = [
            MappingBinding(.lt,.hold,Shortcut(58),"临时吸色"), MappingBinding(.lb,.hold,Shortcut(49),"拖动画布"),
            MappingBinding(.l3,.tap,Shortcut(6,[55]),"撤销"),MappingBinding(.view,.tap,Shortcut(6,[55,56]),"重做"),
            MappingBinding(.menu,.stop,Shortcut(49),"停止映射"),
            MappingBinding(.left,.tap,Shortcut(33),"减小笔刷"),MappingBinding(.right,.tap,Shortcut(30),"增大笔刷"),
            MappingBinding(.up,.tap,Shortcut(24,[55]),"放大画布"),MappingBinding(.down,.tap,Shortcut(27,[55]),"缩小画布"),
            MappingBinding(.a,.tap,Shortcut(11),"画笔"),MappingBinding(.b,.tap,Shortcut(14),"橡皮擦"),
            MappingBinding(.x,.tap,Shortcut(7),"交换颜色"),MappingBinding(.y,.hold,Shortcut(15),"临时旋转视图")]
        for b in active { if let i=bindings.firstIndex(where: {$0.control==b.control}) { bindings[i]=b } }
        var palette=MappingBinding(.lt,.palette,Shortcut(58),"动态调色盘");palette.gesture = .doubleHold
        bindings.append(palette)
        return Profile(bindings: bindings)
    }
    public func validate() throws {
        guard (1...3).contains(schemaVersion) else { throw ProfileError.invalid("不支持的配置版本") }
        let expected = schemaVersion == 1 ? PadControl.legacyControls : Set(PadControl.allCases)
        guard Set(bindings.map(\.control)) == expected, bindings.count <= 240,
              (schemaVersion == 3 ? Set(bindings.map(\.id)).count == bindings.count : bindings.count == expected.count) else {
            throw ProfileError.invalid("配置缺少按键或含重复按键")
        }
        guard targetBundleID.count <= 255, scope != .application || !targetBundleID.trimmingCharacters(in:.whitespaces).isEmpty else { throw ProfileError.invalid("指定应用不能为空") }
        for b in bindings {
            guard b.companions.count<=3,!b.companions.contains(b.control),Set(b.companions).count==b.companions.count else {throw ProfileError.invalid("组合键成员无效")}
            let mac=b.shortcut.encoding == .macOSVirtualKey
            let validKey=b.shortcut.key <= (mac ? 127:0xE7)
            let validModifiers=b.shortcut.modifiers.allSatisfy{mac ? Shortcut.modifierKeys.contains($0):(0xE0...0xE7).contains($0)}
            guard validKey, validModifiers, b.shortcut.modifiers.count <= 4, b.label.count <= 80 else { throw ProfileError.invalid("快捷键或名称无效") }
        }
    }
    public func upgraded() throws -> Profile {
        try validate()
        guard schemaVersion < 3 else { return self }
        var result = self
        result.schemaVersion = 3
        let existing = Set(bindings.map(\.control))
        result.bindings.append(contentsOf: PadControl.allCases.filter { !existing.contains($0) }.map { MappingBinding($0, .disabled) })
        // Recover the default Option hold that older palette migration overwrote.
        // Preserve custom shortcuts and every other control unchanged.
        if let i=result.bindings.firstIndex(where:{$0.control == .lt && $0.mode == .palette && $0.gesture == .doubleHold && $0.companions.isEmpty}),
           !result.bindings.contains(where:{$0.control == .lt && $0.gesture == .press && $0.companions.isEmpty}) {
            let palette=result.bindings[i]
            result.bindings[i]=MappingBinding(.lt,.hold,Shortcut(58),"临时吸色")
            result.bindings.append(palette)
        }
        try result.validate()
        return result
    }
    public func allows(frontBundleID: String?, ownBundleID: String) -> Bool {
        guard let frontBundleID, frontBundleID != ownBundleID else { return false }
        return scope == .global || frontBundleID == targetBundleID
    }
    public func supportsEncoding(_ encoding:ShortcutEncoding)->Bool {
        bindings.allSatisfy{$0.mode == .disabled || $0.mode == .stop || $0.mode == .palette || $0.shortcut.encoding == encoding}
    }
}
public enum ProfileError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(s)=self { return s }; return nil }
}

public extension PadControl {
    static let eliteControls: Set<PadControl> = [.paddle1,.paddle2,.paddle3,.paddle4]
    static let addedControls: Set<PadControl> = [.home,.share,.rightStickLeft,.rightStickRight,.rightStickUp,.rightStickDown,.paddle1,.paddle2,.paddle3,.paddle4]
    static var legacyControls: Set<PadControl> { Set(allCases).subtracting(addedControls) }
    var diagramAnchor: PadControl {
        switch self {
        case .stickLeft,.stickRight,.stickUp,.stickDown: return .l3
        case .rightStickLeft,.rightStickRight,.rightStickUp,.rightStickDown: return .r3
        default: return self
        }
    }
    var stickInputs: [PadControl] {
        if diagramAnchor == .l3 { return [.l3,.stickLeft,.stickRight,.stickUp,.stickDown] }
        if diagramAnchor == .r3 { return [.r3,.rightStickLeft,.rightStickRight,.rightStickUp,.rightStickDown] }
        return []
    }
    var directionGlyph: String? {
        switch self {
        case .stickLeft,.rightStickLeft: return "←"
        case .stickRight,.rightStickRight: return "→"
        case .stickUp,.rightStickUp: return "↑"
        case .stickDown,.rightStickDown: return "↓"
        default: return nil
        }
    }
}

public struct ControllerHotspot: Identifiable {
    public let control: PadControl
    public let x: Double
    public let y: Double
    public let diameter: Double
    public let height: Double
    public var id: PadControl { control }
    public init(_ control: PadControl, _ x: Double, _ y: Double, _ diameter: Double, _ height: Double? = nil) {
        self.control = control; self.x = x; self.y = y; self.diameter = diameter; self.height = height ?? diameter
    }
    public var rotated: ControllerHotspot { ControllerHotspot(control, ControllerLayout.width - x, ControllerLayout.height - y, diameter, height) }
}
public enum ControllerLayout {
    public static let width = 1350.0
    public static let height = 759.0
    // Coordinates refer to the untouched official front image. Stick directions share
    // the physical stick hit area, so no invisible direction button can steal L3/R3 clicks.
    public static let front: [ControllerHotspot] = [
        .init(.home,674,129,74), .init(.share,674,279,54,32),
        .init(.view,604,226,44), .init(.menu,745,226,44),
        .init(.l3,426,228,124), .init(.r3,798,374,124),
        .init(.a,923,294,64), .init(.b,989,230,64),
        .init(.x,858,226,64), .init(.y,923,163,64),
        .init(.left,500,385,48), .init(.right,594,385,48),
        .init(.up,547,337,48), .init(.down,547,431,48)
    ]
    public static let originalTop: [ControllerHotspot] = [
        .init(.rt,310,326,95), .init(.rb,324,190,95),
        .init(.lt,1040,326,95), .init(.lb,1026,190,95)
    ]
    // Rotate the complete photo and its hit targets together; preserve physical input identities.
    public static var intuitiveTop: [ControllerHotspot] { originalTop.map(\.rotated) }
}

public extension Profile {
    func configuredBindings(at anchor: PadControl) -> [MappingBinding] {
        bindings.filter { $0.mode != .disabled && $0.control.diagramAnchor == anchor }
    }
}

/// Stable vertical ordering keeps function labels apart on either side of the photo.
public struct ControllerCallout: Identifiable {
    public let point: ControllerHotspot
    public let left: Bool
    public let position: Double
    public var id: PadControl { point.control }
    public static func placed(points: [ControllerHotspot], profile: Profile) -> [ControllerCallout] {
        let assigned = points.filter { !profile.configuredBindings(at: $0.control).isEmpty }
        return [true,false].flatMap { left in
            let side = assigned.filter { ($0.x < ControllerLayout.width/2) == left }
                .sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
            return side.enumerated().map { index, point in
                ControllerCallout(point: point, left: left, position: Double(index+1)/Double(side.count+1))
            }
        }
    }
}

public struct DiagramPoint: Equatable {
    public let x: Double
    public let y: Double
    public init(_ x: Double, _ y: Double) { self.x=x; self.y=y }
}
public struct DiagramRect {
    public let x: Double, y: Double, width: Double, height: Double
    public init(_ x: Double,_ y: Double,_ width: Double,_ height: Double) { self.x=x; self.y=y; self.width=width; self.height=height }
}
public struct ControllerAnnotation: Identifiable {
    public let control: PadControl
    public let route: [DiagramPoint]
    public let label: DiagramRect
    public var id: PadControl { control }
}
public enum ControllerDiagram {
    public static let width = 1200.0
    public static func height(top: Bool) -> Double { 780 }
    public static func photo(top: Bool) -> DiagramRect {
        let frontWidth=920.0
        let frontScale=frontWidth/ControllerLayout.width
        let centreY=400.0
        if !top{return .init((width-frontWidth)/2,centreY-(ControllerArtworkMetrics.frontBounds.y+ControllerArtworkMetrics.frontBounds.height/2)*frontScale,frontWidth,frontWidth*759/1350)}
        let photoWidth=frontWidth*ControllerArtworkMetrics.frontBounds.width/ControllerArtworkMetrics.shoulderBounds.width
        let scale=photoWidth/ControllerLayout.width
        return .init((width-photoWidth)/2,centreY-(ControllerArtworkMetrics.shoulderBounds.y+ControllerArtworkMetrics.shoulderBounds.height/2)*scale,photoWidth,photoWidth*759/1350)
    }
    /// One common viewport for the two discrete pages. Include visible cutouts
    /// and every configured label, rather than the unused photographic canvas.
    public static func viewport(profile:Profile,annotated:Bool)->DiagramRect {
        guard annotated else{return .init(0,0,width,height(top:false))}
        var rects:[DiagramRect]=[]
        for top in [false,true] {
            let p=photo(top:top), b=ControllerArtworkMetrics.bounds(top:top)
            let scale=p.width/ControllerLayout.width
            rects.append(.init(p.x+b.x*scale,p.y+b.y*scale,b.width*scale,b.height*scale))
            rects += annotations(top:top,profile:profile).map(\.label)
        }
        let minX=max(0,(rects.map(\.x).min() ?? 0)-12)
        let minY=max(0,(rects.map(\.y).min() ?? 0)-12)
        let maxX=min(width,(rects.map{$0.x+$0.width}.max() ?? width)+12)
        let maxY=min(height(top:false),(rects.map{$0.y+$0.height}.max() ?? height(top:false))+12)
        return .init(minX,minY,maxX-minX,maxY-minY)
    }
    public static func transitionViewport(profile:Profile,progress:Double)->DiagramRect {
        transitionViewport(target:viewport(profile:profile,annotated:true),progress:progress)
    }
    public static func transitionViewport(target:DiagramRect,progress:Double)->DiagramRect {
        interpolate(.init(0,0,width,height(top:false)),target,progress)
    }
    public static func transitionPhoto(top:Bool,progress:Double)->DiagramRect {
        interpolate(ControllerArtworkMetrics.expandedPhoto(top:top),photo(top:top),progress)
    }
    private static func interpolate(_ a:DiagramRect,_ b:DiagramRect,_ t:Double)->DiagramRect {
        let t=min(1,max(0,t))
        return .init(a.x+(b.x-a.x)*t,a.y+(b.y-a.y)*t,a.width+(b.width-a.width)*t,a.height+(b.height-a.height)*t)
    }
    public static func annotations(top: Bool, profile: Profile) -> [ControllerAnnotation] {
        allAnnotations(top:top).filter { annotation in
            if !top && [.right,.down].contains(annotation.control){return false}
            return annotationControls(annotation.control).contains{!profile.configuredBindings(at:$0).isEmpty}
        }
    }
    public static func annotationControls(_ control:PadControl)->[PadControl] {
        switch control {case .left:return [.left,.right];case .up:return [.up,.down];default:return [control]}
    }
    public static func allAnnotations(top: Bool) -> [ControllerAnnotation] {
        let photo = photo(top:top)
        let controls = top ? ControllerLayout.intuitiveTop : ControllerLayout.front
        func item(_ c: PadControl,_ points: [(Double,Double)],_ label: DiagramRect) -> ControllerAnnotation {
            let source = controls.first { $0.control == c }!
            let start = DiagramPoint(photo.x+source.x*photo.width/ControllerLayout.width,photo.y+source.y*photo.height/ControllerLayout.height)
            let tail=(c == .home || c == .share) ? Array(points.suffix(1)):Array(points.suffix(2))
            return ControllerAnnotation(control:c,route:[start]+tail.map { .init($0.0,$0.1) },label:label)
        }
        if top {
            return [
                item(.lt,[(360,410),(260,410)],.init(20,384,220,52)),
                item(.lb,[(350,490),(260,490)],.init(20,464,220,52)),
                item(.rt,[(840,410),(940,410)],.init(960,384,220,52)),
                item(.rb,[(850,490),(940,490)],.init(960,464,220,52))
            ]
        }
        return [
            item(.home,[(599,92),(600,82)],.init(490,20,220,52)),
            item(.view,[(564,180),(490,120),(450,120)],.init(210,94,220,52)),
            item(.menu,[(635,180),(710,120),(750,120)],.init(770,94,220,52)),
            item(.share,[(599,650),(600,690)],.init(490,710,220,52)),
            item(.l3,[(400,325),(340,320),(260,320)],.init(20,294,220,52)),
            item(.up,[(465,380),(360,400),(260,400)],.init(20,374,220,52)),
            item(.left,[(440,404),(360,520),(260,520)],.init(20,494,220,52)),
            item(.down,[(535,530),(360,610),(260,610)],.init(20,584,220,52)),
            item(.right,[(559,560),(360,680),(260,680)],.init(20,654,220,52)),
            item(.y,[(830,240),(940,240)],.init(960,214,220,52)),
            item(.b,[(850,320),(940,320)],.init(960,294,220,52)),
            item(.a,[(830,400),(940,400)],.init(960,374,220,52)),
            item(.x,[(704,340),(704,455),(790,500),(940,500)],.init(960,474,220,52)),
            item(.r3,[(662,580),(760,680),(830,680)],.init(850,654,220,52))
        ]
    }
}

public struct ControllerSurface: Identifiable {
    public let top: Bool
    public let photo: DiagramRect
    public var id: Bool { top }
    public init(top: Bool, photo: DiagramRect) { self.top=top; self.photo=photo }
}
public extension ControllerDiagram {
    static func surfaces(top: Bool, combined: Bool) -> [ControllerSurface] {
        if !combined { return [.init(top:top,photo:photo(top:top))] }
        let main=photo(top:false)
        return [.init(top:false,photo:.init(main.x,main.y+200,main.width,main.height)),
                .init(top:true,photo:.init(450,20,300,300*759/1350))]
    }
    static func combinedAnnotations(profile: Profile) -> [ControllerAnnotation] {
        let main=allAnnotations(top:false).map { annotation in
            ControllerAnnotation(control:annotation.control,
                route:annotation.route.map { .init($0.x,$0.y+200) },
                label:.init(annotation.label.x,annotation.label.y+200,annotation.label.width,annotation.label.height))
        }
        let photo=surfaces(top:false,combined:true).first { $0.top }!.photo
        func item(_ control:PadControl,_ bend:DiagramPoint,_ end:DiagramPoint,_ label:DiagramRect) -> ControllerAnnotation {
            let point=ControllerLayout.intuitiveTop.first { $0.control == control }!
            return .init(control:control,route:[.init(photo.x+point.x*photo.width/ControllerLayout.width,photo.y+point.y*photo.height/ControllerLayout.height),bend,end],label:label)
        }
        let top=[item(.lt,.init(440,70),.init(410,70),.init(170,44,220,52)),
                 item(.lb,.init(440,150),.init(410,150),.init(170,124,220,52)),
                 item(.rt,.init(760,70),.init(790,70),.init(810,44,220,52)),
                 item(.rb,.init(760,150),.init(790,150),.init(810,124,220,52))]
        return (main+top).filter { !profile.configuredBindings(at:$0.control).isEmpty }
    }
}

/// Visible silhouette bounds after applying each photo's display rotation.
/// Equalize the physical controller width, not the white JPEG canvas width.
public enum ControllerArtworkMetrics {
    public static let frontBounds=DiagramRect(193,42,964,672)
    public static let shoulderBounds=DiagramRect(83,109,1184,585)
    public static func bounds(top:Bool)->DiagramRect {top ? shoulderBounds : frontBounds}
    public static func physicalWidth(photo:DiagramRect,top:Bool)->Double {photo.width*bounds(top:top).width/ControllerLayout.width}
    public static func expandedPhoto(top:Bool)->DiagramRect {
        let bounds=bounds(top:top)
        let scale=1040/bounds.width
        return .init(600-(bounds.x+bounds.width/2)*scale,390-(bounds.y+bounds.height/2)*scale,ControllerLayout.width*scale,ControllerLayout.height*scale)
    }
}
