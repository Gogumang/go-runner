import Foundation
import Testing
@testable import DeviceTrust

struct AdminConnectionTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("연결 상태마다 점 색이 다르다") func tonePerState() {
        #expect(AdminConnection.disconnected.tone == .neutral)
        #expect(AdminConnection.connecting.tone == .pending)
        #expect(AdminConnection.connected(lastSignalAt: now).tone == .good)
        #expect(AdminConnection.unstable(lastSignalAt: now, reason: "timeout").tone == .bad)
    }

    @Test("불안정해도 세션은 아직 살아 있으니 연결된 것으로 본다") func unstableStillCountsAsConnected() {
        // collector 는 heartbeat 가 3분 끊겨야 세션을 닫는다. 한 번 실패로 "연결 끊기" 메뉴가 사라지면 안 된다.
        #expect(AdminConnection.unstable(lastSignalAt: now, reason: "timeout").isConnected)
        #expect(AdminConnection.connected(lastSignalAt: now).isConnected)
        #expect(!AdminConnection.connecting.isConnected)
        #expect(!AdminConnection.disconnected.isConnected)
    }

    @Test("마지막 신호가 1분 안이면 방금, 넘으면 몇 분 전") func elapsedWording() {
        #expect(AdminConnection.elapsed(since: now.addingTimeInterval(-59), now: now) == "방금")
        #expect(AdminConnection.elapsed(since: now.addingTimeInterval(-125), now: now) == "2분 전")
        // 시계가 뒤로 가도 음수 분이 찍히지 않는다.
        #expect(AdminConnection.elapsed(since: now.addingTimeInterval(30), now: now) == "방금")
    }
}
