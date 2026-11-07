import XCTest
@testable import MappingCore

final class MultifunctionTests:XCTestCase {
    private var pair:[MappingBinding] {Profile.drawing.bindings.filter{$0.control == .lt}}
    private var hold:MappingBinding {pair.first{$0.mode == .hold}!}
    private var palette:MappingBinding {pair.first{$0.mode == .palette}!}
    func testLongFirstPressOnlyHoldsOptionAndReleases(){
        var r=GestureRouter()
        XCTAssertEqual(r.updateBindings(bindings:pair,held:[.lt],time:0,allowed:true),[])
        XCTAssertEqual(r.updateBindings(bindings:pair,held:[.lt],time:0.2,allowed:true),[hold.id])
        XCTAssertEqual(r.updateBindings(bindings:pair,held:[.lt],time:5,allowed:true),[hold.id])
        XCTAssertEqual(r.updateBindings(bindings:pair,held:[],time:5.1,allowed:true),[])
        // A completed long hold must not prime a double click.
        XCTAssertEqual(r.updateBindings(bindings:pair,held:[.lt],time:5.2,allowed:true),[])
        XCTAssertEqual(r.updateBindings(bindings:pair,held:[.lt],time:5.4,allowed:true),[hold.id])
    }
    func testQuickFirstTapNeverEmitsOptionAndSecondHoldOnlyOpensPalette(){
        var r=GestureRouter()
        XCTAssertEqual(r.updateBindings(bindings:pair,held:[.lt],time:0,allowed:true),[])
        XCTAssertEqual(r.updateBindings(bindings:pair,held:[],time:0.08,allowed:true),[])
        XCTAssertEqual(r.updateBindings(bindings:pair,held:[.lt],time:0.15,allowed:true),[])
        XCTAssertEqual(r.updateBindings(bindings:pair,held:[.lt],time:0.34,allowed:true),[palette.id])
        for i in 1...1000 {XCTAssertEqual(r.updateBindings(bindings:pair,held:[.lt],time:0.34+Double(i)/100,allowed:true),[palette.id])}
        XCTAssertEqual(r.updateBindings(bindings:pair,held:[],time:11,allowed:true),[])
    }
    func testDoubleTapAndDoubleHoldAreExclusive(){
        var tap=MappingBinding(.lt,.tap,Shortcut(11));tap.gesture = .doubleTap
        let all=pair+[tap];var r=GestureRouter()
        _=r.updateBindings(bindings:all,held:[.lt],time:0,allowed:true)
        _=r.updateBindings(bindings:all,held:[],time:0.05,allowed:true)
        XCTAssertEqual(r.updateBindings(bindings:all,held:[.lt],time:0.1,allowed:true),[])
        XCTAssertEqual(r.updateBindings(bindings:all,held:[],time:0.15,allowed:true),[tap.id])
        _=r.updateBindings(bindings:all,held:[],time:0.3,allowed:true)
        _=r.updateBindings(bindings:all,held:[.lt],time:1,allowed:true)
        _=r.updateBindings(bindings:all,held:[],time:1.05,allowed:true)
        _=r.updateBindings(bindings:all,held:[.lt],time:1.1,allowed:true)
        XCTAssertEqual(r.updateBindings(bindings:all,held:[.lt],time:1.3,allowed:true),[palette.id])
        XCTAssertEqual(r.updateBindings(bindings:all,held:[],time:1.4,allowed:true),[])
    }
    func testShortSingleTapWaitsForDoubleWindowAndFiresOnce(){
        var single=MappingBinding(.a,.tap,Shortcut(11)),double=MappingBinding(.a,.tap,Shortcut(14));double.gesture = .doubleTap
        single.label="single";var r=GestureRouter();let all=[single,double]
        XCTAssertEqual(r.updateBindings(bindings:all,held:[.a],time:0,allowed:true),[])
        XCTAssertEqual(r.updateBindings(bindings:all,held:[],time:0.05,allowed:true),[])
        XCTAssertEqual(r.updateBindings(bindings:all,held:[],time:0.4,allowed:true),[single.id])
        XCTAssertEqual(r.updateBindings(bindings:all,held:[],time:0.5,allowed:true),[])
        XCTAssertEqual(r.updateBindings(bindings:all,held:[],time:1,allowed:true),[])
    }
    func testScopeLossAndDisconnectReleaseAndRequireNeutral(){
        var r=GestureRouter()
        _=r.updateBindings(bindings:pair,held:[.lt],time:0,allowed:true)
        _=r.updateBindings(bindings:pair,held:[.lt],time:0.2,allowed:true)
        XCTAssertEqual(r.updateBindings(bindings:pair,held:[.lt],time:0.3,allowed:false),[])
        XCTAssertEqual(r.updateBindings(bindings:pair,held:[.lt],time:1,allowed:true),[])
        r.suspend(held:[.lt])
        _=r.updateBindings(bindings:pair,held:[],time:2,allowed:true)
        XCTAssertEqual(r.updateBindings(bindings:pair,held:[.lt],time:3,allowed:true),[])
        XCTAssertEqual(r.updateBindings(bindings:pair,held:[.lt],time:3.2,allowed:true),[hold.id])
    }
    func testChordOverridesEverySingleGestureOnItsMembers(){
        var chord=MappingBinding(.lt,.hold,Shortcut(49));chord.companions=[.rb]
        var r=GestureRouter();let all=pair+[chord]
        _=r.updateBindings(bindings:all,held:[.lt],time:0,allowed:true)
        XCTAssertEqual(r.updateBindings(bindings:all,held:[.lt,.rb],time:0.1,allowed:true),[chord.id])
        XCTAssertEqual(r.updateBindings(bindings:all,held:[.lt],time:0.2,allowed:true),[])
        XCTAssertEqual(r.updateBindings(bindings:all,held:[.lt],time:1,allowed:true),[])
    }
    func testLegacyPaletteMigrationRestoresOptionWithoutChangingOtherControls()throws {
        var old=Profile.drawing;old.schemaVersion=2
        old.bindings.removeAll{$0.control == .lt && $0.mode == .hold}
        let i=old.bindings.firstIndex{$0.control == .lb}!
        old.bindings[i]=MappingBinding(.lb,.tap,Shortcut(6,[55]),"我的撤销")
        let decoded=try JSONDecoder().decode(Profile.self,from:JSONEncoder().encode(old)).upgraded()
        try decoded.validate();XCTAssertEqual(decoded.schemaVersion,3)
        XCTAssertTrue(decoded.bindings.contains{$0.control == .lt && $0.mode == .hold && $0.shortcut.key == 58})
        XCTAssertTrue(decoded.bindings.contains{$0.control == .lt && $0.mode == .palette && $0.gesture == .doubleHold})
        XCTAssertEqual(decoded.bindings.first{$0.control == .lb},old.bindings[i])
        XCTAssertEqual(try decoded.upgraded(),decoded)
    }
    func testOppositeDpadControlsShareTwoCalloutsWithoutLosingBindings(){
        var p=Profile(bindings:PadControl.allCases.map{MappingBinding($0,.disabled)})
        for control:PadControl in [.right,.down] {
            let index=p.bindings.firstIndex{$0.control == control}!
            p.bindings[index].mode = .tap
        }
        let labels=ControllerDiagram.annotations(top:false,profile:p)
        XCTAssertEqual(Set(labels.map(\.control)),[.left,.up])
        XCTAssertEqual(ControllerDiagram.annotationControls(.left),[.left,.right])
        XCTAssertEqual(ControllerDiagram.annotationControls(.up),[.up,.down])
        XCTAssertEqual(p.configuredBindings(at:.right).count,1)
        XCTAssertEqual(p.configuredBindings(at:.down).count,1)
    }
    func testRoundtripPreservesMultipleGesturesAndRejectsDuplicateTrigger()throws {
        var p=Profile.drawing
        var extra=MappingBinding(.lt,.tap,Shortcut(11));extra.gesture = .doubleTap;p.bindings.append(extra)
        try p.validate()
        XCTAssertEqual(try JSONDecoder().decode(Profile.self,from:JSONEncoder().encode(p)),p)
        p.bindings.append(extra);XCTAssertThrowsError(try p.validate())
    }
}
