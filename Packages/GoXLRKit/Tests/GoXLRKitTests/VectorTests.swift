// The Swift codec against Tests/Vectors (transport.json and commands.json).
// policy.json is the dext's: Tests/Policy/check_policy.py runs it.

import Foundation
import XCTest
@testable import GoXLRKit

final class VectorTests: XCTestCase {
    static let vectorsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Vectors")

    func vectors(_ file: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: Self.vectorsDirectory.appendingPathComponent(file))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["vectors"] as? [[String: Any]])
    }

    func testTransportAndCommandVectors() throws {
        var checked = 0
        for file in ["transport.json", "commands.json"] {
            for vector in try vectors(file) {
                let id = vector["id"] as? String ?? "?"
                let bytes = try XCTUnwrap(hex(vector["bytes"] as? String), id)
                let decoded = try XCTUnwrap(vector["decoded"] as? [String: Any], id)
                switch vector["kind"] as? String {
                case "usb-setup": try checkSetup(id, bytes, decoded, vector)
                case "global-data": checkGlobalData(id, bytes, decoded)
                case "dcp-request": checkRequest(id, bytes, decoded)
                case "dcp-reply": try checkReply(id, bytes, decoded, try XCTUnwrap(vector["expect"] as? [String: Any]))
                case "interrupt": try checkInterrupt(id, bytes, decoded)
                case "versions": try checkVersions(id, bytes, decoded)
                case "input-state": try checkInputState(id, bytes, decoded)
                default: XCTFail("\(id): unknown kind")
                }
                checked += 1
            }
        }
        XCTAssertEqual(checked, 38, "every transport and command vector")
    }

    func checkSetup(_ id: String, _ bytes: [UInt8], _ d: [String: Any], _ vector: [String: Any]) throws {
        let setup = USBSetup(bmRequestType: UInt8(d["bmRequestType"] as! Int), bRequest: UInt8(d["bRequest"] as! Int),
                             wValue: UInt16(d["wValue"] as! Int), wIndex: UInt16(d["wIndex"] as! Int),
                             wLength: UInt16(d["wLength"] as! Int))
        XCTAssertEqual(setup.bytes, bytes, id)
        let known: [String: USBSetup] = [
            "setup-read-global-data": .readGlobalData, "setup-reset": .reset,
            "setup-send-command-1-byte-payload": .sendCommand(payloadLength: 1),
            "setup-read-reply-max-1024": .readReply(maxPayload: 1024),
            "setup-uac2-set-cur-48k-clock-41": .setSampleRate48k,
        ]
        XCTAssertEqual(known[id]?.bytes, bytes, "\(id): the codec's constant")
        if let value = d["data_u32"] as? Int {
            let data = try XCTUnwrap(hex(vector["data"] as? String))
            XCTAssertEqual(UInt32(value), data.le32(at: 0), id)
        }
    }

    func checkGlobalData(_ id: String, _ bytes: [UInt8], _ d: [String: Any]) {
        switch GlobalData.parse(bytes) {
        case .success(let global):
            XCTAssertEqual(d["ok"] as? Bool, true, id)
            XCTAssertEqual(Int(global.dcpVersion), d["dcp_version"] as? Int, id)
            XCTAssertEqual(Int(global.maxPayload), d["max_payload"] as? Int, id)
            XCTAssertEqual(global.resetWithBRequest1, d["reset_with_brequest_1"] as? Bool, id)
        case .failure(let failure):
            XCTAssertEqual(d["ok"] as? Bool, false, id)
            XCTAssertEqual("\(failure)", d["error"] as? String, id)
        }
    }

    func checkRequest(_ id: String, _ bytes: [UInt8], _ d: [String: Any]) {
        let encoded = DCP.encodeRequest(category: UInt32(d["category"] as! Int), index: UInt32(d["index"] as! Int),
                                        sequence: UInt16(d["sequence"] as! Int), payload: hex(d["payload"] as? String) ?? [])
        XCTAssertEqual(encoded, bytes, id)
    }

    func checkReply(_ id: String, _ bytes: [UInt8], _ d: [String: Any], _ e: [String: Any]) throws {
        let result = DCP.parseReply(bytes, category: UInt32(e["category"] as! Int), index: UInt32(e["index"] as! Int),
                                    sequence: UInt16(e["sequence"] as! Int), maxPayload: e["max_payload"] as! Int)
        switch result {
        case .success(let payload):
            XCTAssertEqual(d["ok"] as? Bool, true, id)
            XCTAssertEqual(payload, hex(d["payload"] as? String), id)
        case .failure(.dcpStatus(let status)):
            XCTAssertEqual(d["error"] as? String, "dcpStatus", id)
            XCTAssertEqual(Int(status.rawValue), d["status"] as? Int, id)
            XCTAssertEqual(status.name, d["status_name"] as? String, id)
        case .failure(let error):
            XCTAssertEqual(d["ok"] as? Bool, false, id)
            XCTAssertEqual("\(error)", d["error"] as? String, id)
        }
    }

    func checkInterrupt(_ id: String, _ bytes: [UInt8], _ d: [String: Any]) throws {
        let message = try XCTUnwrap(InterruptMessage(bytes), id)
        XCTAssertEqual(message.vendor, d["vendor"] as? Bool, id)
        XCTAssertEqual(message.responseReady, d["response_ready"] as? Bool, id)
        XCTAssertEqual(Int(message.eventFlags), d["event_flags"] as? Int, id)
        XCTAssertEqual(message.readInputState, d["read_input_state"] as? Bool, id)
        if !message.vendor {
            XCTAssertEqual(Int(message.attribute), d["class_attribute"] as? Int, id)
            XCTAssertEqual(Int(message.wValue), d["class_wValue"] as? Int, id)
            XCTAssertEqual(Int(message.wIndex), d["class_wIndex"] as? Int, id)
        }
    }

    func checkVersions(_ id: String, _ bytes: [UInt8], _ d: [String: Any]) throws {
        let versions = try XCTUnwrap(Versions(bytes), id)
        XCTAssertEqual(versions.firmware.map(Int.init), d["firmware"] as? [Int], id)
        XCTAssertEqual(Int(versions.fpgaCount), d["fpga_count"] as? Int, id)
        XCTAssertEqual(Int(versions.diceBuild), d["dice_build"] as? Int, id)
        XCTAssertEqual(versions.diceVersion.map(Int.init), d["dice_version"] as? [Int], id)
    }

    func checkInputState(_ id: String, _ bytes: [UInt8], _ d: [String: Any]) throws {
        let state = try XCTUnwrap(InputState(bytes), id)
        XCTAssertEqual(Int(state.buttons), d["buttons"] as? Int, id)
        XCTAssertEqual(state.pressed, d["pressed"] as? [Int], id)
        XCTAssertEqual(state.encoders.map(Int.init), d["encoders"] as? [Int], id)
        XCTAssertEqual(state.faders.map(Int.init), d["faders"] as? [Int], id)
    }
}

func hex(_ text: String?) -> [UInt8]? {
    guard let text, text.count % 2 == 0 else { return nil }
    var bytes = [UInt8]()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
    }
    return bytes
}
