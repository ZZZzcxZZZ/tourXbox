import XCTest
@testable import MappingCore
final class CoreTests: XCTestCase {
    func testAnnotatedViewportContainsBothPagesWithoutUnusedCanvasSpace() {
        let crop=ControllerDiagram.viewport(profile:.drawing,annotated:true)
        XCTAssertLessThan(crop.height,720)
        for top in [false,true] {
            for a in ControllerDiagram.annotations(top:top,profile:.drawing) {
                XCTAssertGreaterThanOrEqual(a.label.x,crop.x)
                XCTAssertGreaterThanOrEqual(a.label.y,crop.y)
                XCTAssertLessThanOrEqual(a.label.x+a.label.width,crop.x+crop.width)
                XCTAssertLessThanOrEqual(a.label.y+a.label.height,crop.y+crop.height)
            }
        }
    }
    func testDuplicateCallbacksDoNotReleaseAnotherOwner() {
        var l = HoldLedger()
        XCTAssertTrue(l.set(58, owner: "LT", down: true))
        XCTAssertFalse(l.set(58, owner: "LT", down: true))
        XCTAssertFalse(l.set(58, owner: "LB", down: true))
        XCTAssertFalse(l.set(58, owner: "LT", down: false))
        XCTAssertTrue(l.set(58, owner: "LB", down: false))
        XCTAssertFalse(l.set(58, owner: "LB", down: false))
    }
    func testPanicClearsOptionAndSpaceOnce() {
        var l = HoldLedger()
        _ = l.set(58, owner: "a", down: true); _ = l.set(49, owner: "b", down: true)
        XCTAssertEqual(l.clear(), [49, 58]); XCTAssertEqual(l.clear(), [])
    }
    func testTriggerNoise() {
        var h = Hysteresis()
        XCTAssertFalse(h.update(0.54)); XCTAssertTrue(h.update(0.56))
        XCTAssertTrue(h.update(0.40)); XCTAssertTrue(h.update(0.31)); XCTAssertFalse(h.update(0.30))
    }
    func testFocusReturnRequiresNeutral() {
        var g = InputGate()
        XCTAssertEqual(g.update("LT", down: true, allowed: true), true)
        g.suspend()
        XCTAssertNil(g.update("LT", down: true, allowed: true))
        XCTAssertNil(g.update("LT", down: false, allowed: true))
        XCTAssertEqual(g.update("LT", down: true, allowed: true), true)
    }
    func testPressOutsideScopeCannotLeakOnReturn() {
        var g = InputGate()
        XCTAssertNil(g.update("LB", down: true, allowed: false))
        XCTAssertNil(g.update("LB", down: true, allowed: true))
        XCTAssertNil(g.update("LB", down: false, allowed: true))
        XCTAssertEqual(g.update("LB", down: true, allowed: true), true)
    }
}

final class ProfileTests: XCTestCase {
    func testGlobalScopeIncludesFinderAndPhotoshopButPausesEditor() throws {
        let p=Profile.drawing
        try p.validate()
        XCTAssertTrue(p.allows(frontBundleID:"com.apple.finder",ownBundleID:"local.BrushPad.prototype"))
        XCTAssertTrue(p.allows(frontBundleID:"com.adobe.Photoshop",ownBundleID:"local.BrushPad.prototype"))
        XCTAssertFalse(p.allows(frontBundleID:"local.BrushPad.prototype",ownBundleID:"local.BrushPad.prototype"))
        XCTAssertFalse(p.allows(frontBundleID:nil,ownBundleID:"local.BrushPad.prototype"))
    }
    func testSpecifiedAppDoesNotLeakToOtherApps() {
        var p=Profile.drawing; p.scope = .application
        XCTAssertTrue(p.allows(frontBundleID:"com.adobe.Photoshop",ownBundleID:"local.BrushPad.prototype"))
        XCTAssertFalse(p.allows(frontBundleID:"com.apple.finder",ownBundleID:"local.BrushPad.prototype"))
    }
    func testEditedShortcutAndScopeSurviveSaveReload() throws {
        var p=Profile.drawing
        p.scope = .application; p.targetBundleID="org.krita"
        let i=p.bindings.firstIndex{$0.control == .lt}!
        p.bindings[i].shortcut=Shortcut(61)
        p.bindings[i].label="右 Option"
        let reloaded=try JSONDecoder().decode(Profile.self,from:JSONEncoder().encode(p))
        try reloaded.validate()
        XCTAssertEqual(reloaded,p)
        XCTAssertEqual(reloaded.bindings[i].shortcut.key,61)
    }
    func testRejectsMalformedImportedBindings() {
        var p=Profile.drawing
        p.bindings[0].shortcut.modifiers=[11]
        XCTAssertThrowsError(try p.validate())
        p=Profile.drawing; p.bindings[0]=p.bindings[1]
        XCTAssertThrowsError(try p.validate())
        p=Profile.drawing; p.schemaVersion=99
        XCTAssertThrowsError(try p.validate())
    }
    func testChordDoesNotDuplicateItsModifierKey() {
        XCTAssertEqual(Shortcut(58,[58]).keys,[58])
        XCTAssertEqual(Shortcut(6,[55,56]).keys,[55,56,6])
    }
}

final class ControllerCoverageTests: XCTestCase {
    func testLegacyMigrationPreservesEveryExistingBindingAndSettings() throws {
        var old = Profile.drawing
        old.schemaVersion = 1
        old.bindings.removeAll { !PadControl.legacyControls.contains($0.control) || $0.gesture != .press }
        old.scope = .application; old.targetBundleID = "org.krita"; old.bridgePointerFlags = false
        old.bindings[0] = MappingBinding(.lt,.tap,Shortcut(6,[55,56]),"自定义快捷键")
        let data = try JSONEncoder().encode(old)
        let migrated = try JSONDecoder().decode(Profile.self,from:data).upgraded()
        XCTAssertEqual(migrated.schemaVersion,3)
        XCTAssertEqual(migrated.bindings.count,30)
        XCTAssertEqual(Array(migrated.bindings.prefix(20)),old.bindings)
        XCTAssertEqual(migrated.scope,old.scope)
        XCTAssertEqual(migrated.targetBundleID,old.targetBundleID)
        XCTAssertFalse(migrated.bridgePointerFlags)
        XCTAssertTrue(migrated.bindings.filter { PadControl.addedControls.contains($0.control) }.allSatisfy { $0.mode == .disabled })
        XCTAssertEqual(try JSONDecoder().decode(Profile.self,from:JSONEncoder().encode(migrated)),migrated)
    }
    func testInvalidLegacyCannotSilentlyOverwriteMappings() {
        var old = Profile.drawing; old.schemaVersion = 1
        old.bindings.removeAll { !PadControl.legacyControls.contains($0.control) || $0.gesture != .press }
        old.bindings[0] = old.bindings[1]
        XCTAssertThrowsError(try old.upgraded())
        old.bindings.removeLast()
        XCTAssertThrowsError(try old.upgraded())
    }
    func testEveryStandardInputHasAnActualPhysicalTarget() {
        let physical = Set((ControllerLayout.front + ControllerLayout.intuitiveTop).map(\.control))
        XCTAssertEqual(physical.count,18)
        for input in PadControl.allCases where !PadControl.eliteControls.contains(input) {
            XCTAssertTrue(physical.contains(input.diagramAnchor),"Missing \(input)")
        }
        XCTAssertEqual(PadControl.l3.stickInputs.count,5)
        XCTAssertEqual(PadControl.r3.stickInputs.count,5)
    }
    func testNoPhysicalHotspotCanStealAnotherButtonsClick() {
        for points in [ControllerLayout.front, ControllerLayout.intuitiveTop] {
            for (index,a) in points.enumerated() {
                XCTAssertGreaterThanOrEqual(a.x-a.diameter/2,0)
                XCTAssertLessThanOrEqual(a.x+a.diameter/2,ControllerLayout.width)
                XCTAssertGreaterThanOrEqual(a.y-a.diameter/2,0)
                XCTAssertLessThanOrEqual(a.y+a.diameter/2,ControllerLayout.height)
                for b in points.dropFirst(index+1) {
                    let distance = hypot(a.x-b.x,a.y-b.y)
                    XCTAssertGreaterThan(distance,(a.diameter+b.diameter)/2,"Overlapping \(a.control) and \(b.control)")
                }
            }
        }
    }
    func testShoulderPresentationFollowsThePlayersHands() {
        for point in ControllerLayout.intuitiveTop {
            if [.lt,.lb].contains(point.control) { XCTAssertLessThan(point.x,ControllerLayout.width/2) }
            else { XCTAssertGreaterThan(point.x,ControllerLayout.width/2) }
            let original = ControllerLayout.originalTop.first { $0.control == point.control }!
            XCTAssertEqual(original.y+point.y,ControllerLayout.height)
            XCTAssertEqual(original.x+point.x,ControllerLayout.width)
        }
    }
}

final class ConfiguredArtworkTests: XCTestCase {
    func testStickDirectionAssignmentAppearsOnPhysicalStick() {
        var p = Profile.drawing
        XCTAssertTrue(p.configuredBindings(at: .r3).isEmpty)
        let index = p.bindings.firstIndex { $0.control == .rightStickUp }!
        p.bindings[index] = MappingBinding(.rightStickUp,.hold,Shortcut(49),"拖动画布")
        XCTAssertEqual(p.configuredBindings(at: .r3).map(\.control),[.rightStickUp])
        XCTAssertTrue(p.configuredBindings(at: .l3).allSatisfy { $0.control != .rightStickUp })
        p.bindings[index].mode = .disabled
        XCTAssertTrue(p.configuredBindings(at: .r3).isEmpty)
    }
    func testStopIsConfiguredAndUnassignedButtonsStayUnmarked() {
        let p = Profile.drawing
        XCTAssertEqual(p.configuredBindings(at: .menu).first?.mode,.stop)
        XCTAssertTrue(p.configuredBindings(at: .home).isEmpty)
        XCTAssertEqual(p.configuredBindings(at: .lt).first?.shortcut.key,58)
    }
}

final class FunctionCalloutTests: XCTestCase {
    func testCombinedCalloutsCoverEveryAssignedStandardButtonExactlyOnce() {
        let p = Profile.drawing
        let labels = ControllerCallout.placed(points: ControllerLayout.front,profile:p) + ControllerCallout.placed(points: ControllerLayout.intuitiveTop,profile:p)
        let expected = Set(p.bindings.filter { $0.mode != .disabled }.map { $0.control.diagramAnchor })
        XCTAssertEqual(Set(labels.map(\.id)),expected)
        XCTAssertEqual(labels.count,expected.count)
        XCTAssertTrue(labels.contains { $0.id == .lt })
        XCTAssertTrue(labels.contains { $0.id == .menu })
        XCTAssertFalse(labels.contains { $0.id == .share })
    }
    func testLabelsAreInBoundsAndVerticallySeparatedOnEachSide() {
        var p = Profile.drawing
        for index in p.bindings.indices { p.bindings[index].mode = .tap }
        for points in [ControllerLayout.front, ControllerLayout.intuitiveTop] {
            let labels = ControllerCallout.placed(points:points,profile:p)
            for left in [true,false] {
                let side = labels.filter { $0.left == left }
                XCTAssertEqual(side.map(\.position),side.map(\.position).sorted())
                XCTAssertEqual(Set(side.map(\.position)).count,side.count)
                XCTAssertTrue(side.allSatisfy { $0.position > 0 && $0.position < 1 })
            }
        }
    }
    func testUnassignedProfileHasNoLinesAndStickDirectionsShareOneCallout() {
        var p = Profile(bindings: PadControl.allCases.map { MappingBinding($0,.disabled) })
        XCTAssertTrue(ControllerCallout.placed(points:ControllerLayout.front,profile:p).isEmpty)
        for control in [PadControl.r3,.rightStickLeft,.rightStickRight,.rightStickUp,.rightStickDown] {
            p.bindings[p.bindings.firstIndex { $0.control == control }!].mode = .hold
        }
        let labels = ControllerCallout.placed(points:ControllerLayout.front,profile:p)
        XCTAssertEqual(labels.map(\.id),[.r3])
        XCTAssertEqual(p.configuredBindings(at:.r3).count,5)
    }
}

final class GameDiagramRoutingTests: XCTestCase {
    private func cross(_ a:DiagramPoint,_ b:DiagramPoint,_ c:DiagramPoint) -> Double {
        (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
    }
    private func intersect(_ a:DiagramPoint,_ b:DiagramPoint,_ c:DiagramPoint,_ d:DiagramPoint) -> Bool {
        let x1=cross(a,b,c), x2=cross(a,b,d), x3=cross(c,d,a), x4=cross(c,d,b)
        if x1*x2 < -0.00001 && x3*x4 < -0.00001 { return true }
        func on(_ a:DiagramPoint,_ b:DiagramPoint,_ p:DiagramPoint) -> Bool {
            abs(cross(a,b,p)) < 0.00001 && p.x >= min(a.x,b.x)-0.00001 && p.x <= max(a.x,b.x)+0.00001 && p.y >= min(a.y,b.y)-0.00001 && p.y <= max(a.y,b.y)+0.00001
        }
        return on(a,b,c) || on(a,b,d) || on(c,d,a) || on(c,d,b)
    }
    func testTransitionKeepsBothControllerSilhouettesInsideTheViewport() {
        var all=Profile.drawing
        for index in all.bindings.indices {all.bindings[index].mode = .tap}
        for profile in [Profile.drawing,all] {
            for step in 0...200 {
                let t=Double(step)/200,crop=ControllerDiagram.transitionViewport(profile:profile,progress:t)
                var widths:[Double]=[]
                for top in [false,true] {
                    let p=ControllerDiagram.transitionPhoto(top:top,progress:t)
                    let b=ControllerArtworkMetrics.bounds(top:top),scale=p.width/ControllerLayout.width
                    XCTAssertGreaterThanOrEqual(p.x+b.x*scale,crop.x-0.001)
                    XCTAssertGreaterThanOrEqual(p.y+b.y*scale,crop.y-0.001)
                    XCTAssertLessThanOrEqual(p.x+(b.x+b.width)*scale,crop.x+crop.width+0.001)
                    XCTAssertLessThanOrEqual(p.y+(b.y+b.height)*scale,crop.y+crop.height+0.001)
                    widths.append(b.width*scale)
                }
                XCTAssertEqual(widths[0],widths[1],accuracy:0.001)
            }
        }
    }
    func testCalloutsUseAtMostOneElbowAndHorizontalLabelPorts() {
        for top in [false,true] {
            for a in ControllerDiagram.allAnnotations(top:top) {
                XCTAssertLessThanOrEqual(a.route.count,3)
                if a.control != .home && a.control != .share {
                    XCTAssertEqual(a.route[a.route.count-2].y,a.route.last!.y,accuracy:0.001)
                }
            }
        }
    }
    func testAllPhysicalButtonLeadersHaveNoCrossingsOrSharedSegments() {
        var all = Profile.drawing
        for index in all.bindings.indices { all.bindings[index].mode = .tap }
        let layouts = [ControllerDiagram.allAnnotations(top:false),ControllerDiagram.allAnnotations(top:true),ControllerDiagram.combinedAnnotations(profile:all)]
        for annotations in layouts {
            for (index,a) in annotations.enumerated() {
                for b in annotations.dropFirst(index+1) {
                    for i in 0..<(a.route.count-1) {
                        for j in 0..<(b.route.count-1) {
                            XCTAssertFalse(intersect(a.route[i],a.route[i+1],b.route[j],b.route[j+1]),"Crossing \(a.control) / \(b.control)")
                        }
                    }
                }
            }
        }
    }
    func testLabelFramesDoNotOverlapAndRoutesStartAtTheirRealButton() {
        for top in [false,true] {
            let diagram = ControllerDiagram.allAnnotations(top:top)
            let photo = ControllerDiagram.photo(top:top)
            for (index,a) in diagram.enumerated() {
                let source = (top ? ControllerLayout.intuitiveTop : ControllerLayout.front).first { $0.control == a.control }!
                XCTAssertEqual(a.route[0].x,photo.x+source.x*photo.width/ControllerLayout.width,accuracy:0.001)
                XCTAssertEqual(a.route[0].y,photo.y+source.y*photo.height/ControllerLayout.height,accuracy:0.001)
                for b in diagram.dropFirst(index+1) {
                    let xOverlap = min(a.label.x+a.label.width,b.label.x+b.label.width)-max(a.label.x,b.label.x)
                    let yOverlap = min(a.label.y+a.label.height,b.label.y+b.label.height)-max(a.label.y,b.label.y)
                    XCTAssertFalse(xOverlap > 0 && yOverlap > 0,"Overlapping labels \(a.control) / \(b.control)")
                }
            }
        }
    }
    func testUnassignedButtonsDoNotShuffleOtherAnnotations() {
        let original = ControllerDiagram.annotations(top:false,profile:.drawing)
        var p = Profile.drawing
        p.bindings[p.bindings.firstIndex { $0.control == .view }!].mode = .disabled
        let after = ControllerDiagram.annotations(top:false,profile:p)
        XCTAssertEqual(after.count,original.count-1)
        for a in after { XCTAssertEqual(a.route,original.first { $0.control == a.control }!.route) }
    }
}

final class MatchedPerspectiveSizeTests: XCTestCase {
    func testPhysicalWidthsMatchWithFunctionsOnAndOff() {
        for annotated in [false,true] {
            let front=annotated ? ControllerDiagram.photo(top:false) : ControllerArtworkMetrics.expandedPhoto(top:false)
            let shoulder=annotated ? ControllerDiagram.photo(top:true) : ControllerArtworkMetrics.expandedPhoto(top:true)
            for canvasWidth in [600.0,720.0,880.0,1200.0] {
                let frontWidth=ControllerArtworkMetrics.physicalWidth(photo:front,top:false)*canvasWidth/ControllerDiagram.width
                let shoulderWidth=ControllerArtworkMetrics.physicalWidth(photo:shoulder,top:true)*canvasWidth/ControllerDiagram.width
                XCTAssertEqual(frontWidth,shoulderWidth,accuracy:0.001)
            }
        }
        XCTAssertEqual(ControllerDiagram.height(top:false),ControllerDiagram.height(top:true))
    }
    func testFunctionOverlayIsTheOnlyReasonToReduceControllerScale() {
        for top in [false,true] {
            let full=ControllerArtworkMetrics.physicalWidth(photo:ControllerArtworkMetrics.expandedPhoto(top:top),top:top)
            let annotated=ControllerArtworkMetrics.physicalWidth(photo:ControllerDiagram.photo(top:top),top:top)
            XCTAssertEqual(full,1040,accuracy:0.001)
            XCTAssertLessThan(annotated,full)
            XCTAssertGreaterThan(annotated,full*0.6)
        }
    }
}
