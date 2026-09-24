import GoRunnerCore
import Testing

struct DeviceTrustSettingsTests {
    @Test("주소를 비워 두면 기본 주소를 쓴다") func blankFallsBackToDefaults() {
        // 기본값이 생기기 전에 저장된 설정은 adminBaseURL 이 "" 이고, 저장값이 기본값을 이기므로 여기서 메워야 한다.
        var settings = DeviceTrustSettings()
        settings.adminBaseURL = ""
        settings.collectorBaseURL = "  \n"

        #expect(settings.effectiveAdminBaseURL == DeviceTrustSettings.defaultAdminBaseURL)
        #expect(settings.effectiveCollectorBaseURL == DeviceTrustSettings.defaultCollectorBaseURL)
    }

    @Test("입력한 주소는 공백만 떼고 그대로 쓴다") func enteredAddressWins() {
        var settings = DeviceTrustSettings()
        settings.adminBaseURL = " http://localhost:3001 "

        #expect(settings.effectiveAdminBaseURL == "http://localhost:3001")
    }
}
