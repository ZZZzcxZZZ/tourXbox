import XCTest
import ServiceManagement
import MappingCore
@testable import BrushPad

@MainActor private final class FakeLoginItem:LoginItemClient {
    var status:SMAppService.Status = .notRegistered
    var registrations=0,unregistrations=0
    var fail=false
    func register()throws {registrations += 1;if fail {throw NSError(domain:"test",code:1)};status = .requiresApproval}
    func unregister()throws {unregistrations += 1;if fail {throw NSError(domain:"test",code:2)};status = .notRegistered}
}
final class LifecycleTests:XCTestCase {
    func testLoginSettingUsesSystemStatusAndDoesNotRegisterOnLaunch() async {
        await MainActor.run {
            let fake=FakeLoginItem(),prefs=AppLifecyclePreferences(login:fake)
            XCTAssertFalse(prefs.launchAtLogin);XCTAssertEqual(fake.registrations,0)
            prefs.setLaunchAtLogin(true)
            XCTAssertTrue(prefs.launchAtLogin);XCTAssertEqual(prefs.loginStatus,.requiresApproval)
            prefs.setLaunchAtLogin(true);XCTAssertEqual(fake.registrations,1)
            fake.status = .enabled;prefs.refresh();XCTAssertTrue(prefs.launchAtLogin)
            fake.status = .notRegistered;prefs.refresh();XCTAssertFalse(prefs.launchAtLogin)
            prefs.setLaunchAtLogin(true);prefs.setLaunchAtLogin(false)
            XCTAssertFalse(prefs.launchAtLogin);XCTAssertEqual(fake.unregistrations,1)
        }
    }
    func testLoginFailureNeverShowsFalseSuccess() async {
        await MainActor.run {
            let fake=FakeLoginItem();fake.fail=true
            let prefs=AppLifecyclePreferences(login:fake)
            prefs.setLaunchAtLogin(true)
            XCTAssertFalse(prefs.launchAtLogin);XCTAssertNotNil(prefs.loginError)
        }
    }
    func testBackgroundPreferencePersistsIndependentlyOfLoginRegistration() async {
        await MainActor.run {
            let name="tourXbox.lifecycle.test."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
            defer {defaults.removePersistentDomain(forName:name)}
            let fake=FakeLoginItem(),prefs=AppLifecyclePreferences(defaults:defaults,login:fake)
            XCTAssertTrue(prefs.runInBackground)
            prefs.runInBackground=false
            XCTAssertFalse(AppLifecyclePreferences(defaults:defaults,login:fake).runInBackground)
            XCTAssertEqual(fake.registrations,0)
        }
    }
    func testPaletteModelUsesSameProjectionAsRasterWithoutRoundingLightness() async {
        await MainActor.run {
            let model=PaletteModel();model.preferences.focused=false
            model.selectLab(l:37.27,a:128,b:-128)
            XCTAssertEqual(model.labL,37.27)
            XCTAssertEqual(model.color,PaletteRGB.lumaField(light:37.27,a:128,b:-128,focused:false)!)
            XCTAssertEqual(model.color.relativeLuminance,PaletteRGB.luminance(forLabLightness:37.27),accuracy:1e-12)
        }
    }
}

final class DocumentColorTests:XCTestCase {
    func testDisplayP3IsConvertedInsteadOfRelabelled()throws {
        let raw=PaletteRGB(0.5,0.3,0.8)
        let c=try MacPhotoshopTransport.paletteColor(raw,profile:"Display P3")
        XCTAssertGreaterThan(abs(c.r-raw.r),0.02)
        let back=try MacPhotoshopTransport.documentColor(c,profile:"Display P3")
        XCTAssertEqual(back.r,raw.r,accuracy:5e-5);XCTAssertEqual(back.g,raw.g,accuracy:5e-5);XCTAssertEqual(back.b,raw.b,accuracy:5e-5)
    }
    func testSRGBRemainsUnchangedAndUnknownProfilesAreRejected()throws {
        let c=PaletteRGB(0.5,0.3,0.8),back=try MacPhotoshopTransport.paletteColor(c,profile:"sRGB IEC61966-2.1")
        XCTAssertEqual(back.r,c.r,accuracy:5e-5);XCTAssertEqual(back.g,c.g,accuracy:5e-5);XCTAssertEqual(back.b,c.b,accuracy:5e-5)
        XCTAssertThrowsError(try MacPhotoshopTransport.documentSpace("not-an-installed-profile-xyz"))
    }
    func testP3ColorConversionKeepsFullPaletteColorsAtTheSameLuminance()throws {
        for a in stride(from:-128.0,through:128,by:32){for b in stride(from:-128.0,through:128,by:32){
            let c=PaletteRGB.equalLuminanceLab(60,a,b)
            let doc=try MacPhotoshopTransport.documentColor(c,profile:"Display P3")
            let back=try MacPhotoshopTransport.paletteColor(doc,profile:"Display P3")
            XCTAssertEqual(back.relativeLuminance,c.relativeLuminance,accuracy:5e-5)
        }}
    }
}
