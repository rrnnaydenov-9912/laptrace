import XCTest
@testable import LaptraceLogger

final class OBDDecodeTests: XCTestCase {
    func testReadOnlyGuard() {
        for ok in ["ATZ", "ATMA", "ATSH7E0", "0100", "010C0D11", "010C0D111", "0902"] {
            XCTAssertTrue(ELM327Link.isReadOnly(ok), ok)
        }
        // Clear codes, actuator tests, writes by identifier, adapter EEPROM, wake-up messages.
        for blocked in ["04", "14FF00", "2E0101", "3101", "0A", "ATPP 0C SV 23", "ATWM 81 10 F1 3E", "ATSD 12", "", "01 GG"] {
            XCTAssertFalse(ELM327Link.isReadOnly(blocked), blocked)
        }
    }

    func testSingleFrameMultiPID() {
        let v = OBDDecode.mode01(["410C1AF80D3C1166"])
        XCTAssertEqual(OBDDecode.value(pid: 0x0C, v[0x0C]!), 1726)
        XCTAssertEqual(OBDDecode.value(pid: 0x0D, v[0x0D]!), 60)
        XCTAssertEqual(OBDDecode.value(pid: 0x11, v[0x11]!)!, 40, accuracy: 0.1)
    }

    func testMultiFrameReply() {
        let v = OBDDecode.mode01(["00C", "0:410C1AF80D3C", "1:1166494D04800000"])
        XCTAssertEqual(Set(v.keys), [0x0C, 0x0D, 0x11, 0x49, 0x04])
        XCTAssertEqual(OBDDecode.value(pid: 0x04, v[0x04]!)!, 50.2, accuracy: 0.1)
    }

    func testSupportedBitmap() {
        // BE 3E B8 11: 01 03 04 05 06 07 0B 0C 0D 0E 0F 11 13 14 15 1C 20
        let s = OBDDecode.supported(["4100BE3EB811"], base: 0)
        XCTAssertTrue(s.isSuperset(of: [0x0C, 0x0D, 0x11, 0x20]))
        XCTAssertFalse(s.contains(0x10))
    }

    func testCANCandidates() {
        let id = "0C6"
        let quiet = (0..<50).map { OBDDecode.frame("\(id) 7F 00 \(String(format: "%02X", $0 % 256)) 00", t: Double($0))! }
        let steer = (0..<50).map { OBDDecode.frame("\(id) 7F \(String(format: "%02X", $0 * 3)) \(String(format: "%02X", $0 % 256)) 00", t: Double($0))! }
        let c = OBDDecode.candidates(quiet: quiet, active: steer)
        XCTAssertEqual(c.first, .init(id: id, byte: 1, quiet: 1, active: 50))
        XCTAssertNil(OBDDecode.frame("BUFFER FULL", t: 0))
    }
}
