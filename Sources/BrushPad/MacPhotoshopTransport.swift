import AppKit
import Carbon
#if canImport(MappingCore)
import MappingCore
#endif

/// macOS-only adapter. The core contract and color types remain portable.
final class MacPhotoshopTransport:PaletteHostTransport,@unchecked Sendable {
    let readTimeout:TimeInterval
    private let contextLock=NSLock()
    private var context:(document:Int,profile:String)?
    init(readTimeout:TimeInterval=3){self.readTimeout=readTimeout}
    static func documentSpace(_ profile:String)throws->NSColorSpace {
        let normalized=profile.lowercased().filter{$0.isLetter || $0.isNumber}
        if normalized == "displayp3" {return .displayP3}
        if ["srgb","srgbiec6196621"].contains(normalized){return .sRGB}
        if let space=NSColorSpace.availableColorSpaces(with:.rgb).first(where:{($0.localizedName ?? "").lowercased().filter{$0.isLetter || $0.isNumber} == normalized}){return space}
        throw NSError(domain:"tourXbox.ColorProfile",code:1,userInfo:[NSLocalizedDescriptionKey:"无法找到文档色彩配置文件："+profile])
    }
    static func paletteColor(_ rgb:PaletteRGB,profile:String)throws->PaletteRGB {
        guard rgb.inGamut else{throw PaletteHostError.invalidReply}
        let source=try documentSpace(profile)
        guard let c=NSColor(colorSpace:source,components:[rgb.r,rgb.g,rgb.b,1],count:4).usingColorSpace(.extendedSRGB) else{throw PaletteHostError.invalidReply}
        return PaletteRGB(c.redComponent,c.greenComponent,c.blueComponent).luminanceMappedToSRGB
    }
    static func documentColor(_ rgb:PaletteRGB,profile:String)throws->PaletteRGB {
        guard let c=NSColor(srgbRed:rgb.r,green:rgb.g,blue:rgb.b,alpha:1).usingColorSpace(try documentSpace(profile)) else{throw PaletteHostError.invalidRequest}
        return PaletteRGB(c.redComponent,c.greenComponent,c.blueComponent).clipped
    }
    func exchange(_ request:PaletteHostRequest)throws->PaletteHostReply {
        try request.validate()
        let script:String
        switch request.operation {
        case .read:
            script="(function(){if(!app.documents.length)return 'NO_DOCUMENT';if(app.activeDocument.mode!=DocumentMode.RGB)return 'UNSUPPORTED_MODE';var c=app.foregroundColor.rgb;return [c.red,c.green,c.blue,app.activeDocument.id,app.activeDocument.colorProfileName].join('|');})()"
        case .write:
            guard let input=request.color,let id=request.documentID else{throw PaletteHostError.invalidRequest}
            contextLock.lock();let current=context;contextLock.unlock()
            guard let current,current.document==id else{return PaletteHostReply(request:request,status:.invalidContext)}
            let c=try Self.documentColor(input,profile:current.profile)
            let profileLiteral=String(data:try JSONEncoder().encode(current.profile),encoding:.utf8)!
            script="(function(){if(!app.documents.length||app.activeDocument.mode!=DocumentMode.RGB||app.activeDocument.id!=\(id)||app.activeDocument.colorProfileName!==\(profileLiteral))return 'INVALID_CONTEXT';var c=new SolidColor();c.rgb.red=\(c.r*255);c.rgb.green=\(c.g*255);c.rgb.blue=\(c.b*255);app.foregroundColor=c;return 'OK';})()"
        }
        let event=NSAppleEventDescriptor(eventClass:0x6d697363,eventID:0x446a784d,targetDescriptor:NSAppleEventDescriptor(bundleIdentifier:"com.adobe.Photoshop"),returnID:AEReturnID(kAutoGenerateReturnID),transactionID:AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string:script),forKeyword:AEKeyword(keyDirectObject))
        let reply=try event.sendEvent(options:.waitForReply,timeout:request.operation == .read ? readTimeout:1.0)
        if let err=reply.paramDescriptor(forKeyword:AEKeyword(keyErrorNumber)),err.int32Value != 0 {
            throw NSError(domain:"Photoshop",code:Int(err.int32Value),userInfo:[NSLocalizedDescriptionKey:reply.paramDescriptor(forKeyword:AEKeyword(keyErrorString))?.stringValue ?? "Photoshop 忙碌或拒绝了操作"])
        }
        let value=reply.paramDescriptor(forKeyword:AEKeyword(keyDirectObject))?.stringValue ?? reply.stringValue ?? ""
        switch value {
        case "NO_DOCUMENT":return PaletteHostReply(request:request,status:.noDocument)
        case "UNSUPPORTED_MODE":return PaletteHostReply(request:request,status:.unsupportedMode)
        case "INVALID_CONTEXT":return PaletteHostReply(request:request,status:.invalidContext)
        case "OK":return PaletteHostReply(request:request,status:.ok,documentID:request.documentID,color:request.color)
        default:
            let f=value.components(separatedBy:"|")
            guard f.count>=5,let r=Double(f[0]),let g=Double(f[1]),let b=Double(f[2]),let id=Int(f[3]) else{throw PaletteHostError.invalidReply}
            let profile=f.dropFirst(4).joined(separator:"|")
            let color=try Self.paletteColor(PaletteRGB(r/255,g/255,b/255),profile:profile)
            contextLock.lock();context=(id,profile);contextLock.unlock()
            return PaletteHostReply(request:request,status:.ok,documentID:id,color:color,profile:profile)
        }
    }
}
