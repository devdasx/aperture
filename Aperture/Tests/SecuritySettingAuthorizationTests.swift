import Testing
@testable import Aperture

@Suite("Security setting authorization")
struct SecuritySettingAuthorizationTests {
    @Test("Master biometric changes always require biometrics")
    func masterBiometricPolicy() {
        #expect(SecuritySettingChange.biometricEnabled(true).authorization == .biometric)
        #expect(SecuritySettingChange.biometricEnabled(false).authorization == .biometric)
    }

    @Test("Disabling biometric transaction checks requires biometrics")
    func sendPolicy() {
        #expect(SecuritySettingChange.requireBiometricForSend(false).authorization == .biometric)
        #expect(SecuritySettingChange.requireBiometricForSend(true).authorization == .none)
    }

    @Test("Recovery and erase-data changes require the passcode sheet")
    func destructiveSettingPolicy() {
        #expect(SecuritySettingChange.forgotPasscodeResetEnabled(true).authorization == .passcode)
        #expect(SecuritySettingChange.forgotPasscodeResetEnabled(false).authorization == .passcode)
        #expect(SecuritySettingChange.eraseDataEnabled(true).authorization == .passcode)
        #expect(SecuritySettingChange.eraseDataEnabled(false).authorization == .passcode)
    }
}
