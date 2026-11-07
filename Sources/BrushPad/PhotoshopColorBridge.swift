import AppKit
#if canImport(MappingCore)
import MappingCore
#endif

/// Uses Photoshop's installed, public scripting dictionary. Never activates Photoshop,
/// creates a document, changes a document's profile or launches a missing application.
@MainActor final class PhotoshopColorBridge:ObservableObject {
    @Published private(set) var status="未连接 Photoshop"
    @Published private(set) var connected=false
    private let queue=DispatchQueue(label:"tourXbox.PhotoshopColor",qos:.userInitiated)
    private let transport:any PaletteHostTransport = MacPhotoshopTransport()
    private var session=UUID().uuidString
    private var sequence:UInt64=0
    private var busy=false
    private var pending:PaletteRGB?
    private var generation=0
    private var targetPID:pid_t?
    private var documentID:Int?
    var onRead:((PaletteRGB)->Void)?
    var onFailure:(()->Void)?
    var enabled=false
    private(set) var readCount=0
    private(set) var writeCount=0
    private var lastSend=0.0
    private var delayed:DispatchWorkItem?
    func invalidate() {generation += 1;session=UUID().uuidString;pending=nil;delayed?.cancel();delayed=nil;targetPID=nil;documentID=nil;connected=false}
    func read(allowWhileConfiguring:Bool=false) {
        guard !busy else{return}
        guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:"com.adobe.Photoshop").first,
              allowWhileConfiguring || NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier else {
            status="请先切到已打开的 Photoshop 文档";return
        }
        if let targetPID,targetPID != app.processIdentifier {invalidate();status="Photoshop 已重新启动，请重新呼出调色盘";onFailure?();return}
        targetPID=app.processIdentifier
        status="正在读取 Photoshop 前景色…"
        sequence += 1
        let request=PaletteHostRequest(session:session,sequence:sequence,operation:.read)
        readCount += 1
        perform(request) { [weak self] result in
            guard let self else{return}
            switch result {
            case .success(let value):
                let fields=value.components(separatedBy:"|")
                if fields.count>=5,let r=Double(fields[0]),let g=Double(fields[1]),let b=Double(fields[2]),let id=Int(fields[3]) {
                    if let old=self.documentID,old != id {self.invalidate();self.status="文档已切换，旧调色会话已取消";self.onFailure?();return}
                    self.documentID=id
                    self.connected=true;self.status="Photoshop 已连接 · \(fields[4])"
                    self.onRead?(PaletteRGB(r/255,g/255,b/255).clipped)
                } else {self.connected=false;self.status=value=="NO_DOCUMENT" ? "Photoshop 尚未打开文档":"暂不支持当前文档模式"}
            case .failure(let error):self.failed(error)
            }
        }
    }
    func submit(_ color:PaletteRGB) {
        guard enabled,connected,let pid=targetPID,NSWorkspace.shared.frontmostApplication?.processIdentifier==pid else{return}
        pending=color.clipped;drain()
    }
    private func drain() {
        guard !busy, pending != nil else{return}
        let delay=max(0,1.0/20-(ProcessInfo.processInfo.systemUptime-lastSend))
        if delay>0 {
            guard delayed==nil else{return}
            let work=DispatchWorkItem{[weak self] in self?.delayed=nil;self?.drain()};delayed=work
            DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:work);return
        }
        guard let pid=targetPID,let documentID,NSWorkspace.shared.frontmostApplication?.processIdentifier==pid else{pending=nil;return}
        let c=pending!;pending=nil;lastSend=ProcessInfo.processInfo.systemUptime
        sequence += 1
        let request=PaletteHostRequest(session:session,sequence:sequence,operation:.write,documentID:documentID,color:c)
        writeCount += 1
        perform(request) { [weak self] result in
            guard let self else{return}
            switch result {case .failure(let error):self.failed(error);case .success(let value):if value != "OK" {self.connected=false;self.status="文档状态已改变，已停止写色";self.pending=nil}}
        }
    }
    private func failed(_ error:Error) {
        connected=false;pending=nil
        let e=error as NSError
        status=e.code == -1743 ? "Photoshop 自动化尚未获系统许可（与辅助功能不同）":"Photoshop 连接失败：\(e.localizedDescription)"
        onFailure?()
    }
    private func perform(_ request:PaletteHostRequest,completion:@escaping(Result<String,Error>)->Void) {
        guard !busy else{return};busy=true
        let token=generation,transport=self.transport
        queue.async { [weak self] in
            let result:Result<String,Error>
            do {
                let reply=try transport.exchange(request)
                guard reply.version==1,reply.session==request.session,reply.sequence==request.sequence else{throw PaletteHostError.invalidReply}
                let value:String
                switch reply.status {
                case .noDocument:value="NO_DOCUMENT"
                case .unsupportedMode:value="UNSUPPORTED_MODE"
                case .invalidContext:value="INVALID_CONTEXT"
                case .ok:
                    if request.operation == .read,let c=reply.color,let id=reply.documentID {
                        value="\(c.r*255)|\(c.g*255)|\(c.b*255)|\(id)|\(reply.profile ?? "RGB")"
                    } else {value="OK"}
                }
                result = .success(value)
            } catch {result = .failure(error)}
            DispatchQueue.main.async { [weak self] in
                guard let self else{return};self.busy=false
                guard self.generation==token else{self.drain();return}
                completion(result);self.drain()
            }
        }
    }
}
