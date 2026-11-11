import XCTest
@testable import WallpaperMachine

/// Logon and request routing against a scripted connection manager.
final class SteamCMConnectionTests: XCTestCase {
    private func api() -> FakeSteamWebAPI {
        let api = FakeSteamWebAPI()
        api.serve("ISteamDirectory/GetCMListForConnect/v1/",
                  json: #"{"response":{"serverlist":[{"endpoint":"cm.test:443","type":"websockets"}],"success":true}}"#)
        return api
    }

    func testLogOnSendsTheTokenAndAdoptsTheSessionSteamGives() async throws {
        let token = SteamTestToken.token()
        let socket = ScriptedCMSocket { packet in
            packet.emsg == SteamCMConnection.EMsg.clientLogon
                ? [ScriptedCMSocket.logOnReply(steamID: token.steamID, cellID: 14)] : []
        }
        let connection = SteamCMConnection(api: api(), opener: socket, timeout: .seconds(5))
        try await connection.logOn(with: token, machineName: "Test Mac")

        let loggedOn = await connection.isLoggedOn
        let cellID = await connection.cellID
        XCTAssertTrue(loggedOn)
        XCTAssertEqual(cellID, 14)
        let logon = try XCTUnwrap(socket.sent.first { $0.emsg == SteamCMConnection.EMsg.clientLogon })
        XCTAssertEqual(logon.header.fixed64(1), token.steamID)
        let body = try SteamProto.Message(logon.body)
        XCTAssertEqual(body.string(108), token.value)
        XCTAssertEqual(body.string(96), "Test Mac")
        await connection.disconnect()
    }

    func testARefusedLogOnReportsSteamsReason() async throws {
        let token = SteamTestToken.token()
        let socket = ScriptedCMSocket { _ in [ScriptedCMSocket.logOnReply(eresult: 5, steamID: token.steamID)] }
        let connection = SteamCMConnection(api: api(), opener: socket, timeout: .seconds(5))
        do {
            try await connection.logOn(with: token, machineName: "Test Mac")
            XCTFail("expected the refusal")
        } catch let failure as SteamCMConnection.Failure {
            XCTAssertEqual(failure, .logOnRefused(eresult: 5))
        }
        let loggedOn = await connection.isLoggedOn
        XCTAssertFalse(loggedOn)
    }

    func testServiceRepliesArriveByJobEvenInsideACompressedMulti() async throws {
        let token = SteamTestToken.token()
        let socket = ScriptedCMSocket { packet in
            switch packet.emsg {
            case SteamCMConnection.EMsg.clientLogon:
                return [ScriptedCMSocket.logOnReply(steamID: token.steamID)]
            case SteamCMConnection.EMsg.serviceMethodCallFromClient:
                let job = packet.header.fixed64(10)!
                var body = SteamProto.Writer()
                body.varint(1, job * 100)
                let reply = ScriptedCMSocket.frame(SteamCMConnection.EMsg.serviceMethodResponse,
                                                   jobTarget: job, eresult: 1, body: body)
                // An unrelated message first, so routing must go by job id.
                let noise = ScriptedCMSocket.frame(9999, body: SteamProto.Writer())
                return [Self.multi([noise, reply])]
            default:
                return []
            }
        }
        let connection = SteamCMConnection(api: api(), opener: socket, timeout: .seconds(5))
        try await connection.logOn(with: token, machineName: "Test Mac")
        async let first = connection.serviceMethod("Test.First#1", Data())
        async let second = connection.serviceMethod("Test.Second#1", Data())
        let answers = try await [first.varint(1), second.varint(1)].compactMap { $0 }
        XCTAssertEqual(Set(answers), [100, 200])
        let names = socket.sent.compactMap { $0.header.string(12) }
        XCTAssertEqual(Set(names), ["Test.First#1", "Test.Second#1"])
        await connection.disconnect()
    }

    func testAFailedServiceReplyAndASilentOneBothThrow() async throws {
        let token = SteamTestToken.token()
        let socket = ScriptedCMSocket { packet in
            switch packet.emsg {
            case SteamCMConnection.EMsg.clientLogon:
                return [ScriptedCMSocket.logOnReply(steamID: token.steamID)]
            case SteamCMConnection.EMsg.serviceMethodCallFromClient where packet.header.string(12) == "Test.Refused#1":
                return [ScriptedCMSocket.frame(SteamCMConnection.EMsg.serviceMethodResponse,
                                               jobTarget: packet.header.fixed64(10)!, eresult: 15, body: SteamProto.Writer())]
            default:
                return []
            }
        }
        let connection = SteamCMConnection(api: api(), opener: socket, timeout: .milliseconds(300))
        try await connection.logOn(with: token, machineName: "Test Mac")
        do {
            _ = try await connection.serviceMethod("Test.Refused#1", Data())
            XCTFail("expected the refusal")
        } catch let failure as SteamCMConnection.Failure {
            XCTAssertEqual(failure, .requestFailed("Test.Refused#1", eresult: 15))
        }
        do {
            _ = try await connection.serviceMethod("Test.Silent#1", Data())
            XCTFail("expected a timeout")
        } catch let failure as SteamCMConnection.Failure {
            XCTAssertEqual(failure, .timedOut("Test.Silent#1"))
        }
        await connection.disconnect()
    }

    func testRequestsBeforeLogOnAreRefused() async {
        let connection = SteamCMConnection(api: api(), opener: ScriptedCMSocket { _ in [] })
        do {
            _ = try await connection.serviceMethod("Test.Any#1", Data())
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? SteamCMConnection.Failure, .notLoggedOn)
        }
    }

    /// A gzip-compressed `Multi` holding `frames`.
    private static func multi(_ frames: [Data]) -> Data {
        var payload = Data()
        for frame in frames {
            withUnsafeBytes(of: UInt32(frame.count).littleEndian) { payload.append(contentsOf: $0) }
            payload.append(frame)
        }
        let deflated = try! (payload as NSData).compressed(using: .zlib) as Data
        let gzip = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3]) + deflated + Data(count: 8)
        var body = SteamProto.Writer()
        body.varint(1, UInt64(payload.count))
        body.bytes(2, gzip)
        return ScriptedCMSocket.frame(SteamCMConnection.EMsg.multi, body: body)
    }
}
