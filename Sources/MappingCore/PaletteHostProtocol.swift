import Foundation

/// Platform-neutral, versioned host contract. Windows may implement this with a
/// UXP/IPC adapter; no HWND, pid_t, Apple Event or NSColor crosses this boundary.
public struct PaletteHostRequest:Codable,Equatable,Sendable {
    public enum Operation:String,Codable,Sendable {case read,write}
    public var version=1
    public var session:String
    public var sequence:UInt64
    public var operation:Operation
    public var documentID:Int?
    public var color:PaletteRGB?
    public init(session:String,sequence:UInt64,operation:Operation,documentID:Int?=nil,color:PaletteRGB?=nil){self.session=session;self.sequence=sequence;self.operation=operation;self.documentID=documentID;self.color=color}
    public func validate() throws {
        guard version==1,!session.isEmpty,session.utf8.count<=128 else{throw PaletteHostError.invalidRequest}
        if operation == .write {guard documentID != nil,let color,color.inGamut else{throw PaletteHostError.invalidRequest}}
    }
}
public struct PaletteHostReply:Codable,Equatable,Sendable {
    public enum Status:String,Codable,Sendable {case ok,noDocument,unsupportedMode,invalidContext}
    public var version=1
    public var session:String
    public var sequence:UInt64
    public var status:Status
    public var documentID:Int?
    public var color:PaletteRGB?
    public var profile:String?
    public init(request:PaletteHostRequest,status:Status,documentID:Int?=nil,color:PaletteRGB?=nil,profile:String?=nil){session=request.session;sequence=request.sequence;self.status=status;self.documentID=documentID;self.color=color;self.profile=profile}
}
public enum PaletteHostError:Error {case invalidRequest,invalidReply}
public protocol PaletteHostTransport:Sendable {
    /// Blocking exchange runs only on a platform worker queue, never the UI thread.
    func exchange(_ request:PaletteHostRequest)throws->PaletteHostReply
}
