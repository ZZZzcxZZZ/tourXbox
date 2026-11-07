import AppKit
let out=URL(fileURLWithPath:CommandLine.arguments[1])
let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
NSColor.clear.setFill();NSRect(x:0,y:0,width:1024,height:1024).fill()
let base=NSFont.systemFont(ofSize:256,weight:.bold)
let font=base.fontDescriptor.withDesign(.rounded).flatMap{NSFont(descriptor:$0,size:256)} ?? base
let attrs:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:NSColor.white,.kern:-7]
for (text,y) in [("tour",500.0),("Xbox",252.0)] {
    let word=text as NSString
    word.draw(at:NSPoint(x:200,y:y),withAttributes:attrs)
}
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using:.png,properties:[:])!.write(to:out)
