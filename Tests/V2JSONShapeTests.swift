//
//  V2JSONShapeTests.swift
//  Treetracker-CoreTests
//
//  Pins the JSON keys and explicit nulls to what Android sends
//  (treetracker-android: UploadRequestsJsonShapeTest).
//

import Foundation
import Testing
@testable import Treetracker_Core

@Suite("v2 JSON shape")
struct V2JSONShapeTests {

    private let capturedAt = Date(timeIntervalSince1970: 1_709_288_130.5)

    private func object(_ bundle: V2UploadBundle) throws -> [String: Any] {
        let encoded = try bundle.encoded()
        return try #require(try JSONSerialization.jsonObject(with: Data(encoded.json.utf8)) as? [String: Any])
    }

    @Test func envelopeWritesEveryKeyWithNullsForOtherSections() throws {
        let bundle = V2UploadBundle.sessions([], deviceId: "DEVICE")
        let json = try object(bundle)

        #expect(Set(json.keys) == [
            "pack_format_version", "device_id", "wallet_registrations", "captures",
            "device_configurations", "sessions", "tracks", "messages"
        ])
        #expect(json["pack_format_version"] as? String == "2")
        #expect(json["device_id"] as? String == "DEVICE")
        #expect(json["captures"] is NSNull)
        #expect(json["wallet_registrations"] is NSNull)
        #expect(json["device_configurations"] is NSNull)
        #expect(json["tracks"] is NSNull)
        #expect(json["messages"] is NSNull)
        #expect(json["sessions"] as? [Any] != nil)
    }

    @Test func captureKeysAndNulls() throws {
        let request = TreeCaptureRequest(
            sessionId: "SESSION",
            treeId: "TREE",
            latitude: -3.3869,
            longitude: 36.683,
            note: nil,
            imageUrl: "https://images.example.invalid/a.jpg",
            capturedAt: capturedAt
        )
        let json = try object(.captures([request], deviceId: "DEVICE"))
        let capture = try #require((json["captures"] as? [[String: Any]])?.first)

        #expect(Set(capture.keys) == [
            "session_id", "id", "lat", "lon", "note", "image_url", "captured_at",
            "abs_step_count", "delta_step_count", "rotation_matrix", "extra_attributes"
        ])
        #expect(capture["session_id"] as? String == "SESSION")
        #expect(capture["id"] as? String == "TREE")
        #expect(capture["lat"] as? Double == -3.3869)
        #expect(capture["lon"] as? Double == 36.683)
        #expect(capture["note"] is NSNull)
        #expect(capture["image_url"] as? String == "https://images.example.invalid/a.jpg")
        #expect(capture["captured_at"] as? String == "2024-03-01T10:15:30.500Z")
        #expect(capture["abs_step_count"] is NSNull)
        #expect(capture["delta_step_count"] is NSNull)
        #expect(capture["rotation_matrix"] is NSNull)
        #expect(capture["extra_attributes"] is NSNull)
    }

    @Test func urlsAreNotSlashEscaped() throws {
        let request = TreeCaptureRequest(
            sessionId: "S", treeId: "T", latitude: 0, longitude: 0, note: "",
            imageUrl: "https://images.example.invalid/a.jpg", capturedAt: capturedAt
        )
        let encoded = try V2UploadBundle.captures([request], deviceId: "D").encoded()
        #expect(encoded.json.contains("https://images.example.invalid/a.jpg"))
        #expect(!encoded.json.contains("\\/"))
    }

    @Test func sessionKeys() throws {
        let request = SessionRequest(
            sessionId: "SESSION",
            originatingWalletRegistrationId: "PLANTER",
            targetWallet: "planter@example.org",
            organization: "",
            deviceConfigurationId: "CONFIG"
        )
        let session = try #require((try object(.sessions([request], deviceId: "D"))["sessions"] as? [[String: Any]])?.first)
        #expect(session as NSDictionary == [
            "id": "SESSION",
            "originating_wallet_registration_id": "PLANTER",
            "target_wallet": "planter@example.org",
            "organization": "",
            "device_configuration_id": "CONFIG"
        ] as NSDictionary)
    }

    @Test func walletRegistrationKeysAndNulls() throws {
        let request = WalletRegistrationRequest(
            registrationId: "PLANTER",
            wallet: "planter@example.org",
            userPhotoUrl: "https://images.example.invalid/selfie.jpg",
            firstName: "Ada",
            lastName: "Planter",
            phone: nil,
            email: "planter@example.org",
            latitude: 1.5,
            longitude: 2.5,
            registeredAt: capturedAt
        )
        let registration = try #require((try object(.walletRegistrations([request], deviceId: "D"))["wallet_registrations"] as? [[String: Any]])?.first)
        #expect(Set(registration.keys) == [
            "id", "wallet", "user_photo_url", "first_name", "last_name", "phone", "email", "lat", "lon", "registered_at"
        ])
        #expect(registration["phone"] is NSNull)
        #expect(registration["registered_at"] as? String == "2024-03-01T10:15:30.500Z")
    }

    @Test func deviceConfigurationKeys() throws {
        let request = DeviceConfigRequest(
            configurationId: "CONFIG",
            deviceIdentifier: "DEVICE",
            appVersion: "2.0",
            appBuild: 42,
            manufacturer: "Apple",
            brand: "Apple",
            model: "iPhone",
            hardware: "iPhone15,2",
            device: "iPhone15,2",
            osVersion: "17.2",
            sdkVersion: 17,
            loggedAt: capturedAt
        )
        let configuration = try #require((try object(.deviceConfigurations([request], deviceId: "D"))["device_configurations"] as? [[String: Any]])?.first)
        #expect(Set(configuration.keys) == [
            "id", "device_identifier", "app_version", "app_build", "manufacturer", "brand", "model",
            "hardware", "device", "serial", "os_version", "sdk_version", "instance_id", "logged_at"
        ])
        #expect(configuration["app_build"] as? Int == 42)
        #expect(configuration["sdk_version"] as? Int == 17)
        #expect(configuration["serial"] as? String == "unknown")
    }

    @Test func tracksUseCamelCaseKeys() throws {
        let request = TracksRequest(
            sessionId: "SESSION",
            locations: [TrackLocationRequest(accuracy: 4.5, capturedAt: capturedAt, latitude: 1, longitude: 2)]
        )
        let track = try #require((try object(.tracks([request], deviceId: "D"))["tracks"] as? [[String: Any]])?.first)
        #expect(Set(track.keys) == ["sessionId", "locations"])
        let location = try #require((track["locations"] as? [[String: Any]])?.first)
        #expect(Set(location.keys) == ["accuracy", "capturedAt", "latitude", "longitude"])
    }

    @Test(arguments: zip(
        [
            V2UploadBundle.deviceConfigurations([], deviceId: "D"),
            V2UploadBundle.walletRegistrations([], deviceId: "D"),
            V2UploadBundle.sessions([], deviceId: "D"),
            V2UploadBundle.captures([], deviceId: "D"),
            V2UploadBundle.tracks([], deviceId: "D")
        ],
        ["_deviceConfigs", "_registrations", "_sessions", "_captures", "_tracks"]
    ))
    func bundleIdIsMD5PlusSuffix(bundle: V2UploadBundle, suffix: String) throws {
        let encoded = try bundle.encoded()
        #expect(encoded.bundleId == encoded.json.md5 + suffix)
        #expect(encoded.bundleId.count == 32 + suffix.count)
    }

    @Test func bundleKeyTimestampMatchesAndroidFormat() {
        let stamp = V2DateFormatter.bundleKeyTimestamp(from: capturedAt)
        #expect(stamp.range(of: #"^\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}$"#, options: .regularExpression) != nil)
    }
}
