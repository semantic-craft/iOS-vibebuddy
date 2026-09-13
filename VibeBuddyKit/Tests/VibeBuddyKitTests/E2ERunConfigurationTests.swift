import Testing
@testable import VibeBuddyKit

@Suite("Explicit E2E namespace configuration")
struct E2ERunConfigurationTests {
    private var environment: [String: String] {
        ["VIBEBUDDY_E2E_ROOT": "/tmp/vibebuddy-probe-1",
         "VIBEBUDDY_E2E_ID": "probe-1", "VIBEBUDDY_E2E_PORT": "19876"]
    }

    @Test("Ordinary environment leaves every override absent")
    func ordinaryLaunch() throws {
        #expect(try E2ERunConfiguration(environment: ["PATH": "/bin"], bundleIdentifier: "com.vibebuddy.mac") == nil)
    }

    @Test("An E2E app relaunched without its environment refuses production fallback")
    func isolatedBundleWithoutEnvironment() {
        #expect(throws: E2ERunConfiguration.ConfigurationError.self) {
            try E2ERunConfiguration(environment: ["PATH": "/bin"], bundleIdentifier: "com.vibebuddy.e2e.probe-1")
        }
    }

    @Test("Valid run confines names, paths and flags to the explicit namespace")
    func validRun() throws {
        let config = try #require(try E2ERunConfiguration(environment: environment, bundleIdentifier: "com.vibebuddy.e2e.probe-1"))
        #expect(config.root.path == "/tmp/vibebuddy-probe-1")
        #expect(config.file("token").path == "/tmp/vibebuddy-probe-1/token")
        #expect(config.keychainService == "com.vibebuddy.e2e.probe-1.secrets")
        #expect(config.host == "127.0.0.1" && config.port == 19876)
        #expect(!config.audioEnabled && !config.notificationsEnabled)
        var enabled = environment
        enabled["VIBEBUDDY_E2E_AUDIO"] = "1"
        enabled["VIBEBUDDY_E2E_NOTIFICATIONS"] = "1"
        enabled["VIBEBUDDY_E2E_HOST"] = "192.168.1.23"
        enabled["VIBEBUDDY_E2E_CODEX_THREAD"] = "12345678-1234-1234-1234-123456789abc"
        let staged = try #require(try E2ERunConfiguration(environment: enabled, bundleIdentifier: "com.vibebuddy.e2e.probe-1"))
        #expect(staged.audioEnabled && staged.notificationsEnabled)
        #expect(staged.host == "192.168.1.23" && staged.codexThreadID == enabled["VIBEBUDDY_E2E_CODEX_THREAD"])
        enabled["VIBEBUDDY_E2E_HOST"] = "100.64.0.2"
        let tailnet = try #require(try E2ERunConfiguration(environment: enabled, bundleIdentifier: "com.vibebuddy.e2e.probe-1"))
        #expect(tailnet.host == "100.64.0.2")
    }

    @Test("Partial, conflicting and malformed explicit inputs refuse production fallback")
    func invalidRun() {
        let replacements = [
            ["VIBEBUDDY_E2E_ID": "Probe-1"],
            ["VIBEBUDDY_E2E_ROOT": "relative"],
            ["VIBEBUDDY_E2E_ROOT": "/"],
            ["VIBEBUDDY_E2E_PORT": "9876"],
            ["VIBEBUDDY_E2E_PORT": "1023"],
            ["VIBEBUDDY_E2E_PORT": "65536"],
            ["VIBEBUDDY_E2E_PORT": "+19876"],
            ["VIBEBUDDY_E2E_AUDIO": "0"],
            ["VIBEBUDDY_E2E_HOST": "0.0.0.0"],
            ["VIBEBUDDY_E2E_HOST": "example.com"],
            ["VIBEBUDDY_E2E_HOST": "8.8.8.8"],
            ["VIBEBUDDY_E2E_HOST": "100.63.255.255"],
            ["VIBEBUDDY_E2E_HOST": "100.128.0.1"],
            ["VIBEBUDDY_E2E_CODEX_THREAD": "not-a-thread"],
            ["VIBEBUDDY_E2E_UNKNOWN": "1"]]
        for replacement in replacements {
            let values = environment.merging(replacement) { _, new in new }
            #expect(throws: E2ERunConfiguration.ConfigurationError.self) {
                try E2ERunConfiguration(environment: values, bundleIdentifier: "com.vibebuddy.e2e.probe-1")
            }
        }
        for key in environment.keys {
            var missing = environment; missing.removeValue(forKey: key)
            #expect(throws: E2ERunConfiguration.ConfigurationError.self) {
                try E2ERunConfiguration(environment: missing, bundleIdentifier: "com.vibebuddy.e2e.probe-1")
            }
        }
        #expect(throws: E2ERunConfiguration.ConfigurationError.self) {
            try E2ERunConfiguration(environment: environment, bundleIdentifier: "com.vibebuddy.mac")
        }
    }
}
