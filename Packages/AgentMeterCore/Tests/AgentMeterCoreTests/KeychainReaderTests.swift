import Foundation
import Testing
@testable import AgentMeterCore

#if os(macOS)
struct KeychainReaderTests {

    @Test func decodesWrappedCredentialsIgnoringSiblingKeys() throws {
        // /login 后的真实结构:claudeAiOauth 旁边多了 trustedDeviceToken 字符串。
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "atk",
            "refreshToken": "rtk",
            "expiresAt": 1781474284318,
            "scopes": ["user:inference", "user:profile"],
            "subscriptionType": "max",
            "rateLimitTier": "default_claude_max"
          },
          "trustedDeviceToken": "some-device-token"
        }
        """
        let creds = try KeychainReader.decodeCredentials(Data(json.utf8))
        #expect(creds.accessToken == "atk")
        #expect(creds.scopes?.contains("user:inference") == true)
        #expect(creds.subscriptionType == "max")
        // expiresAt 是 epoch 毫秒,转成 Date。
        #expect(abs(creds.expiresAt!.timeIntervalSince1970 - 1781474284.318) < 1)
    }

    @Test func decodesTopLevelCredentials() throws {
        let json = """
        { "accessToken": "atk", "scopes": ["user:inference"] }
        """
        let creds = try KeychainReader.decodeCredentials(Data(json.utf8))
        #expect(creds.accessToken == "atk")
    }

    @Test func decodesWrappedCodexCredentials() throws {
        let json = """
        {
          "codexOauth": {
            "accessToken": "codex-atk",
            "expiresAt": 1781474284318,
            "subscriptionType": "Plus"
          },
          "deviceId": "ignored"
        }
        """
        let creds = try KeychainReader.decodeCredentials(Data(json.utf8), tool: .codex)
        #expect(creds.accessToken == "codex-atk")
        #expect(creds.subscriptionType == "Plus")
        #expect(abs(creds.expiresAt!.timeIntervalSince1970 - 1781474284.318) < 1)
    }

    @Test func codexCanDecodeTopLevelCredentials() throws {
        let json = #"{ "accessToken": "codex-atk", "subscriptionType": "Pro" }"#
        let creds = try KeychainReader.decodeCredentials(Data(json.utf8), tool: .codex)
        #expect(creds.accessToken == "codex-atk")
        #expect(creds.subscriptionType == "Pro")
    }

    @Test func decodesCodexAuthFileCredentials() throws {
        let json = """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "access_token": "codex-atk",
            "refresh_token": "codex-rtk",
            "account_id": "acct"
          },
          "last_refresh": "2026-06-14T14:00:00Z"
        }
        """
        let creds = try KeychainReader.decodeCodexAuthFile(Data(json.utf8))
        #expect(creds.accessToken == "codex-atk")
        #expect(creds.refreshToken == "codex-rtk")
    }

    @Test func missingAccessTokenThrows() {
        let json = #"{ "claudeAiOauth": { "refreshToken": "x" } }"#
        #expect(throws: KeychainReader.ReadError.self) {
            try KeychainReader.decodeCredentials(Data(json.utf8))
        }
    }
}
#endif
