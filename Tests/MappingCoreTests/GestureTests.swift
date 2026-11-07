import XCTest
@testable import MappingCore

final class GestureTests:XCTestCase {
    func testDoubleHoldRequiresReleaseSecondPressAndHoldThenReleases(){
        var router=GestureRouter(),b=MappingBinding(.rt,.palette)
        b.gesture = .doubleHold
        XCTAssertEqual(router.update(bindings:[b],held:[.rt],time:0,allowed:true),[])
        XCTAssertEqual(router.update(bindings:[b],held:[.rt],time:1,allowed:true),[])
        XCTAssertEqual(router.update(bindings:[b],held:[],time:1.1,allowed:true),[])
        XCTAssertEqual(router.update(bindings:[b],held:[.rt],time:1.2,allowed:true),[])
        XCTAssertEqual(router.update(bindings:[b],held:[.rt],time:1.37,allowed:true),[])
        XCTAssertEqual(router.update(bindings:[b],held:[.rt],time:1.4,allowed:true),[.rt])
        XCTAssertEqual(router.update(bindings:[b],held:[.rt],time:5,allowed:true),[.rt])
        XCTAssertEqual(router.update(bindings:[b],held:[],time:5.01,allowed:true),[])
    }
    func testDoubleTapTimeoutAndQuickSecondRelease(){
        var router=GestureRouter(),b=MappingBinding(.a,.tap)
        b.gesture = .doubleTap
        _=router.update(bindings:[b],held:[.a],time:0,allowed:true)
        _=router.update(bindings:[b],held:[],time:0.1,allowed:true)
        XCTAssertEqual(router.update(bindings:[b],held:[.a],time:0.5,allowed:true),[])
        _=router.update(bindings:[b],held:[],time:0.6,allowed:true)
        XCTAssertEqual(router.update(bindings:[b],held:[.a],time:0.7,allowed:true),[.a])
        XCTAssertEqual(router.update(bindings:[b],held:[],time:0.71,allowed:true),[])
    }
    func testChordConsumesMemberSinglesAndDoesNotRetriggerOnPartnerRelease(){
        var router=GestureRouter(),a=MappingBinding(.a,.tap)
        a.companions=[.lb]
        let lb=MappingBinding(.lb,.hold,Shortcut(49))
        XCTAssertEqual(router.update(bindings:[a,lb],held:[.lb],time:0,allowed:true),[])
        XCTAssertEqual(router.update(bindings:[a,lb],held:[.lb,.a],time:0.1,allowed:true),[.a])
        XCTAssertEqual(router.update(bindings:[a,lb],held:[.lb],time:0.2,allowed:true),[])
        XCTAssertEqual(router.update(bindings:[a,lb],held:[],time:0.3,allowed:true),[])
        _=router.update(bindings:[a,lb],held:[.lb],time:0.5,allowed:true)
        XCTAssertEqual(router.update(bindings:[a,lb],held:[.lb],time:0.7,allowed:true),[.lb])
    }
    func testScopeTransitionCannotActivateAnAlreadyHeldGesture(){
        var router=GestureRouter();let b=MappingBinding(.lt,.hold,Shortcut(58))
        XCTAssertEqual(router.update(bindings:[b],held:[.lt],time:0,allowed:true),[.lt])
        XCTAssertEqual(router.update(bindings:[b],held:[.lt],time:0.1,allowed:false),[])
        XCTAssertEqual(router.update(bindings:[b],held:[.lt],time:0.2,allowed:true),[])
        _=router.update(bindings:[b],held:[],time:0.3,allowed:true)
        XCTAssertEqual(router.update(bindings:[b],held:[.lt],time:0.4,allowed:true),[.lt])
    }
    func testOldConfigurationDecodesWithPlainPressAndNoChord()throws {
        let b=try JSONDecoder().decode(MappingBinding.self,from:Data("{\"control\":\"a\",\"mode\":\"tap\",\"shortcut\":{\"key\":11,\"modifiers\":[]},\"label\":\"画笔\"}".utf8))
        XCTAssertEqual(b.gesture,.press);XCTAssertTrue(b.companions.isEmpty)
        let p=Profile.drawing
        XCTAssertEqual(p.bindings.first{$0.control == .lt && $0.mode == .palette}?.gesture,.doubleHold)
        try p.validate()
    }
}
