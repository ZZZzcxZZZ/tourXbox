import XCTest
@testable import BrushPad
import MappingCore

final class OutputCacheTests:XCTestCase {
    func testModifierCacheTracksMultipleOwnersAndOrdinaryHeldKeys() async {
        await MainActor.run {
            let output=EventOutput();output.dryRun=true
            let a=MappingBinding(.a,.hold,Shortcut(58),"Option A")
            let b=MappingBinding(.b,.hold,Shortcut(58),"Option B")
            let space=MappingBinding(.x,.hold,Shortcut(49),"Space")
            output.apply(space,down:true);XCTAssertTrue(output.modifierFlags.isEmpty)
            output.apply(a,down:true);XCTAssertTrue(output.modifierFlags.contains(.maskAlternate))
            output.apply(b,down:true);output.apply(a,down:false)
            XCTAssertTrue(output.modifierFlags.contains(.maskAlternate))
            output.apply(b,down:false);XCTAssertTrue(output.modifierFlags.isEmpty)
            XCTAssertFalse(output.ledger.owners.isEmpty)
            output.releaseAll();XCTAssertTrue(output.ledger.owners.isEmpty)
            XCTAssertTrue(output.modifierFlags.isEmpty)
        }
    }
    func testSamePhysicalButtonHasIndependentHoldOwners() async {
        await MainActor.run {
            let output=EventOutput();output.dryRun=true
            let a=MappingBinding(.lt,.hold,Shortcut(58))
            var b=a;b.gesture = .doubleHold
            output.apply(a,down:true);output.apply(b,down:true)
            output.apply(a,down:false)
            XCTAssertTrue(output.modifierFlags.contains(.maskAlternate))
            XCTAssertEqual(output.ledger.owners[58],[b.id])
            output.apply(b,down:false);XCTAssertTrue(output.ledger.owners.isEmpty)
        }
    }
    func testLTGestureRoutingProducesNoOptionDuringPaletteAndBalancedLongHold() async {
        await MainActor.run {
            let bindings=Profile.drawing.bindings.filter{$0.control == .lt}
            var router=GestureRouter(),active=Set<String>()
            let output=EventOutput();output.dryRun=true;var events:[String]=[];output.log={events.append($0)}
            @MainActor func step(_ held:Set<PadControl>,_ time:Double){
                let routed=router.updateBindings(bindings:bindings,held:held,time:time,allowed:true)
                for b in bindings where b.mode != .palette {
                    if routed.contains(b.id) != active.contains(b.id){output.apply(b,down:routed.contains(b.id))}
                }
                active=routed
            }
            step([.lt],0);step([],0.06);step([.lt],0.12);step([.lt],0.4);step([.lt],5);step([],5.1)
            XCTAssertTrue(events.isEmpty);XCTAssertTrue(output.ledger.owners.isEmpty)
            step([.lt],6);step([.lt],6.2)
            XCTAssertTrue(output.modifierFlags.contains(.maskAlternate))
            for i in 1...1000 {step([.lt],6.2+Double(i)/100)}
            step([],17)
            XCTAssertEqual(events.count,2)
            XCTAssertTrue(output.modifierFlags.isEmpty);XCTAssertTrue(output.ledger.owners.isEmpty)
        }
    }
    func testFailedDownRollsBackCachedModifierState() async {
        await MainActor.run {
            let output=EventOutput();var checks=0
            output.canSend={checks += 1;return checks==1}
            output.apply(MappingBinding(.a,.hold,Shortcut(58),"Option"),down:true)
            XCTAssertTrue(output.modifierFlags.isEmpty)
            XCTAssertTrue(output.ledger.owners.isEmpty)
        }
    }
    func testRepeatedHoldsAndReleaseAllKeepCachedFlagsBalanced() async {
        await MainActor.run {
            let output=EventOutput();output.dryRun=true
            let held=MappingBinding(.a,.hold,Shortcut(58,[55]),"Option Command")
            for _ in 0..<1000{output.apply(held,down:true)}
            XCTAssertTrue(output.modifierFlags.contains([.maskAlternate,.maskCommand]))
            output.releaseAll();output.releaseAll()
            XCTAssertTrue(output.modifierFlags.isEmpty)
            XCTAssertTrue(output.ledger.owners.isEmpty)
        }
    }
}
