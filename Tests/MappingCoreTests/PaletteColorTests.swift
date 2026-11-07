import XCTest
@testable import MappingCore

final class PaletteColorTests:XCTestCase {
    func testWheelShapesAreInscribedAtAllSizes(){
        for scale in [0.85,1.0,1.2] {
            let g=PaletteWheelGeometry(diameter:270*scale,ringWidth:22*scale)
            XCTAssertEqual(hypot(g.squareSide/2,g.squareSide/2),g.innerRadius,accuracy:1e-10)
            // Triangle vertices must share the wheel's centre, not the bounding box centre.
            let left = -g.triangleWidth/2+g.triangleCenterOffset
            let right=g.triangleWidth/2+g.triangleCenterOffset
            XCTAssertEqual(hypot(left,g.triangleHeight/2),g.innerRadius,accuracy:1e-10)
            XCTAssertEqual(right,g.innerRadius,accuracy:1e-10)
        }
    }
    func testWheelContentRetainsBreathingSpaceAtAllSizes(){
        for scale in [0.85,1.0,1.2] {
            let ring=PaletteWheelGeometry(diameter:270*scale,ringWidth:22*scale)
            let content=PaletteWheelGeometry(diameter:270*scale,ringWidth:22*scale,contentInset:8*scale)
            XCTAssertEqual(ring.innerRadius-hypot(content.squareSide/2,content.squareSide/2),8*scale,accuracy:1e-10)
            XCTAssertEqual(ring.innerRadius-content.triangleWidth/2-content.triangleCenterOffset,8*scale,accuracy:1e-10)
        }
    }
    func testStationaryStickNoiseDoesNotEnterEditingOrWriteColors(){
        var dial=StickDialPrototype()
        _=dial.update(x:1,y:0,time:1)
        for i in 1...100 {
            let a=i%2==0 ? 0.002 : -0.002
            XCTAssertEqual(dial.update(x:cos(a),y:sin(a),time:1+Double(i)*0.01).radians,0)
        }
        XCTAssertNotEqual(dial.update(x:cos(0.1),y:sin(0.1),time:2.01).radians,0)
    }
    func testHeldButtonIgnoresRepeatedPacketsAndShortFalsePackets(){
        var button=StableButton(),ledger=HoldLedger(),edges:[Bool]=[]
        for i in 0...1000 {
            let t=Double(i)/1000
            // Two brief false packets during a one-second continuous hold.
            let raw = !(0.2...0.21).contains(t) && !(0.6...0.62).contains(t)
            let stable=button.update(raw,time:t)
            if ledger.set(58,owner:"hold",down:stable){edges.append(stable)}
        }
        XCTAssertEqual(edges,[true])
        XCTAssertTrue(button.update(false,time:1.01))
        XCTAssertFalse(button.update(false,time:1.05))
        if ledger.set(58,owner:"hold",down:false){edges.append(false)}
        XCTAssertEqual(edges,[true,false])
        XCTAssertTrue(ledger.owners.isEmpty)
        XCTAssertTrue(button.update(true,time:1.06))
    }
    func testOptionAndSpaceOwnersReleaseExactlyOnce(){
        for key:UInt16 in [58,49] {
            var ledger=HoldLedger()
            XCTAssertTrue(ledger.set(key,owner:"trigger",down:true))
            for _ in 0..<1000 {XCTAssertFalse(ledger.set(key,owner:"trigger",down:true))}
            XCTAssertFalse(ledger.set(key,owner:"palette",down:true))
            XCTAssertFalse(ledger.set(key,owner:"trigger",down:false))
            XCTAssertTrue(ledger.set(key,owner:"palette",down:false))
            XCTAssertFalse(ledger.set(key,owner:"palette",down:false))
            XCTAssertTrue(ledger.owners.isEmpty)
        }
    }
    func testHSVAndHSLRoundTripsAcrossGamut(){
        for r in 0...8 {for g in 0...8 {for b in 0...8 {
            let c=PaletteRGB(Double(r)/8,Double(g)/8,Double(b)/8),v=c.hsv,l=c.hsl
            for back in [PaletteRGB.hsv(v.h,v.s,v.v),PaletteRGB.hsl(l.h,l.s,l.l)] {
                XCTAssertEqual(back.r,c.r,accuracy:1e-8);XCTAssertEqual(back.g,c.g,accuracy:1e-8);XCTAssertEqual(back.b,c.b,accuracy:1e-8)
            }
        }}}
    }
    func testLabRoundTripAndOutOfGamutMask(){
        for c in [PaletteRGB(0,0,0),PaletteRGB(1,1,1),PaletteRGB(1,0,0),PaletteRGB(0,1,0),PaletteRGB(0,0,1),PaletteRGB(0.1,0.6,0.7)] {
            let l=c.lab,back=PaletteRGB.lab(l.l,l.a,l.b)
            XCTAssertEqual(back.r,c.r,accuracy:2e-5);XCTAssertEqual(back.g,c.g,accuracy:2e-5);XCTAssertEqual(back.b,c.b,accuracy:2e-5)
        }
        XCTAssertFalse(PaletteRGB.lab(60,100,100).inGamut)
        XCTAssertTrue(PaletteRGB.lab(60,0,0).inGamut)
    }
    func testHSLTriangleInverseAndVertices(){
        for s in stride(from:0.0,through:1.0,by:0.1){for l in stride(from:0.1,through:0.9,by:0.1){
            let point=PaletteRGB.trianglePoint(s:s,l:l),value=PaletteRGB.triangle(point.x,point.y)
            XCTAssertEqual(value.s,s,accuracy:1e-8);XCTAssertEqual(value.l,l,accuracy:1e-8)
        }}
        XCTAssertEqual(PaletteRGB.triangle(0,0).l,1)
        XCTAssertEqual(PaletteRGB.triangle(0,1).l,0)
        XCTAssertEqual(PaletteRGB.triangle(1,0.5).s,1)
    }
    func testNewActionRoundTripDoesNotChangeExistingBindings() throws {
        var p=Profile.drawing
        let old=p.bindings.filter{$0.control != .rb}
        p.bindings[p.bindings.firstIndex{$0.control == .rb}!]=MappingBinding(.rb,.palette,Shortcut(58),"动态调色盘")
        let decoded=try JSONDecoder().decode(Profile.self,from:JSONEncoder().encode(p)).upgraded()
        XCTAssertEqual(decoded.bindings.filter{$0.control != .rb},old)
        XCTAssertEqual(decoded.bindings.first{$0.control == .rb}?.mode,.palette)
    }
    func testPortableHostProtocolRejectsMalformedWrites() throws {
        let request=PaletteHostRequest(session:"portable-test",sequence:7,operation:.write,documentID:42,color:PaletteRGB(0.2,0.4,0.6))
        try request.validate()
        XCTAssertEqual(try JSONDecoder().decode(PaletteHostRequest.self,from:JSONEncoder().encode(request)),request)
        XCTAssertThrowsError(try PaletteHostRequest(session:"x",sequence:0,operation:.write).validate())
        XCTAssertThrowsError(try PaletteHostRequest(session:"x",sequence:0,operation:.write,documentID:1,color:PaletteRGB(.nan,0,0)).validate())
        let reply=PaletteHostReply(request:request,status:.ok,documentID:42,color:request.color,profile:"sRGB IEC61966-2.1")
        XCTAssertEqual(try JSONDecoder().decode(PaletteHostReply.self,from:JSONEncoder().encode(reply)),reply)
    }
    func testPortableDialDoesNotRepeatWhenHeldOffCenter(){
        var dial=StickDialPrototype()
        XCTAssertEqual(dial.update(x:1,y:0,time:1).steps,0)
        XCTAssertEqual(dial.update(x:1,y:0,time:1.01).radians,0)
        let turn=dial.update(x:0.8,y:-0.6,time:1.02)
        XCTAssertGreaterThan(turn.radians,0)
        XCTAssertEqual(dial.update(x:0.8,y:-0.6,time:1.03).steps,0)
        _=dial.update(x:0,y:0,time:1.04)
        XCTAssertEqual(dial.update(x:0,y:1,time:1.05).steps,0)
    }
    func testLegacyKeyEncodingAndForeignEncodingGate()throws {
        let legacy=try JSONDecoder().decode(Shortcut.self,from:Data("{\"key\":58,\"modifiers\":[]}".utf8))
        XCTAssertEqual(legacy.encoding,.macOSVirtualKey)
        var p=Profile.drawing
        let i=p.bindings.firstIndex{$0.control == .y}!
        p.bindings[i].shortcut.encoding = .usbHID
        p.bindings[i].shortcut.key=0xE2
        try p.validate()
        XCTAssertFalse(p.supportsEncoding(.macOSVirtualKey))
    }
}
