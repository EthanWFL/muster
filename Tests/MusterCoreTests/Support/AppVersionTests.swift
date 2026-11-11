import Testing
@testable import MusterCore

struct AppVersionTests {
    @Test func parsesLeadingVAndShortForms() {
        #expect(AppVersion("v1.2.3") == AppVersion(major: 1, minor: 2, patch: 3))
        #expect(AppVersion("2") == AppVersion(major: 2))
        #expect(AppVersion("0.3") == AppVersion(major: 0, minor: 3))
    }

    @Test func ignoresPrereleaseAndBuildMetadata() {
        #expect(AppVersion("1.2.3-beta.1+abc") == AppVersion(major: 1, minor: 2, patch: 3))
        #expect(AppVersion("v1.0.0-rc1") == AppVersion("1.0.0"))
    }

    @Test func rejectsMalformedStrings() {
        for bad in ["", "v", "abc", "1.2.3.4", "1..2", "1.x", "-1.0", "１.0"] {
            #expect(AppVersion(bad) == nil, "\(bad)")
        }
    }

    @Test func comparesNumericallyNotLexically() {
        #expect(AppVersion("1.10.0")! > AppVersion("1.9.9")!)
        #expect(AppVersion("2")! > AppVersion("1.99.99")!)
        #expect(AppVersion("1.2")! == AppVersion("1.2.0")!)
    }

    @Test func isNewerHandlesEqualOlderAndGarbage() {
        #expect(AppVersion.isNewer("v0.2.0", than: "0.1.0"))
        #expect(!AppVersion.isNewer("0.1.0", than: "0.1.0"))
        #expect(!AppVersion.isNewer("0.0.9", than: "0.1.0"))
        #expect(!AppVersion.isNewer("nightly", than: "0.1.0"))
        #expect(!AppVersion.isNewer("0.2.0", than: "dev"))
    }
}
