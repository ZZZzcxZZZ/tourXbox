import AppKit
import Carbon
#if canImport(MappingCore)
import MappingCore
#endif

/// macOS-only adapter. The core contract and color types remain portable.
struct MacPhotoshopTransport:PaletteHostTransport {
    var readTimeout:TimeInterval=3
    func exchange(_ request:PaletteHostRequest)throws->PaletteHostReply {
        try request.validate()
        let script:String
        switch request.operation {
        case .read:
            script="(function(){if(!app.documents.length)return 'NO_DOCUMENT';if(app.activeDocument.mode!=DocumentMode.RGB)return 'UNSUPPORTED_MODE';var c=app.foregroundColor.rgb;return [c.red,c.green,c.blue,app.activeDocument.id,app.activeDocument.colorProfileName].join('|');})()"
        case .write:
            guard let c=request.color,let id=request.documentID else{throw PaletteHostError.invalidRequest}
            script="(function(){if(!app.documents.length||app.activeDocument.mode!=DocumentMode.RGB||app.activeDocument.id!=\(id))return 'INVALID_CONTEXT';var c=new SolidColor();c.rgb.red=\(c.r*255);c.rgb.green=\(c.g*255);c.rgb.blue=\(c.b*255);app.foregroundColor=c;return 'OK';})()"
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
            return PaletteHostReply(request:request,status:.ok,documentID:id,color:PaletteRGB(r/255,g/255,b/255).clipped,profile:f.dropFirst(4).joined(separator:"|"))
        }
    }
}
