import XCTest
@testable import MappingCore

final class LumaTests:XCTestCase {
    func testFullFieldKeepsLuminanceAcrossHueAndOutOfGamutCoordinates(){
        var oldWorst=0.0,newWorst=0.0
        for l in [1.0,8,20,40,60,80,99] {
            let target=PaletteRGB.luminance(forLabLightness:l)
            for a in stride(from:-128.0,through:128,by:8){for b in stride(from:-128.0,through:128,by:8){
                let c=PaletteRGB.lumaField(light:l,a:a,b:b,focused:false)!
                XCTAssertTrue(c.inGamut)
                let error=abs(c.relativeLuminance-target)
                newWorst=max(newWorst,error)
                oldWorst=max(oldWorst,abs(PaletteRGB.lab(l,a,b).clipped.relativeLuminance-target))
                XCTAssertLessThan(error,1e-12)
            }}
        }
        print("LUMA_AUDIT worst linear-Y error old=\(oldWorst) new=\(newWorst)")
        XCTAssertGreaterThan(oldWorst,0.1)
    }
    func testFocusedFieldRejectsUnavailableColorsButAcceptedColorsHaveSameY(){
        XCTAssertNil(PaletteRGB.lumaField(light:60,a:100,b:100,focused:true))
        var accepted=0
        for a in stride(from:-100.0,through:100,by:5){for b in stride(from:-100.0,through:100,by:5){
            if let c=PaletteRGB.lumaField(light:37.27,a:a,b:b,focused:true){
                accepted += 1
                XCTAssertEqual(c.relativeLuminance,PaletteRGB.luminance(forLabLightness:37.27),accuracy:1e-12)
            }
        }}
        XCTAssertGreaterThan(accepted,50)
    }
    func testNeutralAndBlackWhiteEndpointsAreCorrect(){
        for a in [-128.0,0,128]{for b in [-128.0,0,128]{
            XCTAssertEqual(PaletteRGB.equalLuminanceLab(0,a,b),PaletteRGB(0,0,0))
            XCTAssertEqual(PaletteRGB.equalLuminanceLab(100,a,b),PaletteRGB(1,1,1))
        }}
        for l in 0...100 {
            let c=PaletteRGB.equalLuminanceLab(Double(l),0,0)
            XCTAssertEqual(c.r,c.g,accuracy:3e-7);XCTAssertEqual(c.g,c.b,accuracy:3e-7)
        }
    }
    func testInGamutColorSurvivesProjection(){
        for c in [PaletteRGB(0.1,0.6,0.7),PaletteRGB(0.7,0.2,0.3),PaletteRGB(0.3,0.3,0.3)] {
            let lab=c.lab,back=PaletteRGB.equalLuminanceLab(lab.l,lab.a,lab.b)
            XCTAssertEqual(back.r,c.r,accuracy:2e-5);XCTAssertEqual(back.g,c.g,accuracy:2e-5);XCTAssertEqual(back.b,c.b,accuracy:2e-5)
        }
    }
    func testSliderHasStrictlyIncreasingYEvenForSaturatedColors(){
        for (a,b) in [(100.0,100.0),(-100.0,100.0),(100.0,-100.0)] {
            var previous = -1.0
            for l in 0...100 {
                let c=PaletteRGB.equalLuminanceLab(Double(l),a,b)
                XCTAssertGreaterThan(c.relativeLuminance,previous);previous=c.relativeLuminance
            }
        }
    }
    func testFullFieldPerformance(){
        let start=Date();var checksum=0.0
        for y in 0..<270 {for x in 0..<270 {
            checksum += PaletteRGB.lumaField(light:60,a:(Double(x)/269-0.5)*256,b:(0.5-Double(y)/269)*256,focused:false)!.r
        }}
        print("LUMA_RASTER 270x270 seconds=\(Date().timeIntervalSince(start)) checksum=\(checksum)")
        XCTAssertTrue(checksum.isFinite)
    }
}
