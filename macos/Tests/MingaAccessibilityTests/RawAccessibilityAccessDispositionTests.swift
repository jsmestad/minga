import ApplicationServices
import XCTest

final class RawAccessibilityAccessDispositionTests: XCTestCase {
    func testUntrustedRunnerIsInfrastructure() {
        switch RawAccessibilityAccessDisposition.classify(trusted: false, result: .success) {
        case .infrastructure:
            break
        case .available, .targetFailure:
            XCTFail("An untrusted runner must be classified as missing infrastructure")
        }
    }

    func testTrustedSuccessfulProbeIsAvailable() {
        switch RawAccessibilityAccessDisposition.classify(trusted: true, result: .success) {
        case .available:
            break
        case .infrastructure, .targetFailure:
            XCTFail("A trusted successful probe must be available")
        }
    }

    func testTrustedPermissionDisabledProbeIsInfrastructure() {
        switch RawAccessibilityAccessDisposition.classify(trusted: true, result: .apiDisabled) {
        case .infrastructure:
            break
        case .available, .targetFailure:
            XCTFail("A disabled Accessibility API must be classified as missing infrastructure")
        }
    }

    func testTrustedTargetErrorRemainsAProductFailure() {
        switch RawAccessibilityAccessDisposition.classify(trusted: true, result: .cannotComplete) {
        case .targetFailure(let error):
            XCTAssertEqual(error, .cannotComplete)
        case .available, .infrastructure:
            XCTFail("A trusted target-side AX error must remain a product failure")
        }
    }
}
