import Testing
@testable import BacktickCore

@Suite("JSONValue")
struct JSONValueTests {
    @Test func numbersZeroAndOneStayNumbers() {
        let v = JSONValue.parse(#"{"index": 1, "exit_code": 0, "ok": true, "off": false, "ratio": 0.5}"#)
        #expect(v?["index"] == .number(1))
        #expect(v?["exit_code"] == .number(0))
        #expect(v?["ok"] == .bool(true))
        #expect(v?["off"] == .bool(false))
        #expect(v?["ratio"] == .number(0.5))
    }

    @Test func parseAndDecodeAgree() throws {
        let text = #"{"a":[1,0,true,null,"s"],"b":{"c":1}}"#
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(JSONValue.parse(text) == decoded)
    }
}

import Foundation
