//
//  V2UploadBundle.swift
//  Treetracker-Core
//

import Foundation

/// The envelope for every v2 upload pack. Mirrors Android's `UploadBundle.createV2`.
///
/// Each bundle carries one section. The other section keys are still written as `null`,
/// because Android encodes with `explicitNulls = true` and `encodeDefaults = true`.
struct V2UploadBundle: Encodable, Sendable {

    static let packFormatVersion = "2"

    enum Kind: String, Sendable {
        case deviceConfigurations = "_deviceConfigs"
        case walletRegistrations = "_registrations"
        case sessions = "_sessions"
        case captures = "_captures"
        case tracks = "_tracks"

        /// The suffix appended to the md5 of the bundle JSON to form the bundle id.
        var bundleIdSuffix: String { rawValue }
    }

    let kind: Kind
    let deviceId: String
    let walletRegistrations: [WalletRegistrationRequest]?
    let captures: [TreeCaptureRequest]?
    let deviceConfigurations: [DeviceConfigRequest]?
    let sessions: [SessionRequest]?
    let tracks: [TracksRequest]?

    private init(
        kind: Kind,
        deviceId: String,
        walletRegistrations: [WalletRegistrationRequest]? = nil,
        captures: [TreeCaptureRequest]? = nil,
        deviceConfigurations: [DeviceConfigRequest]? = nil,
        sessions: [SessionRequest]? = nil,
        tracks: [TracksRequest]? = nil
    ) {
        self.kind = kind
        self.deviceId = deviceId
        self.walletRegistrations = walletRegistrations
        self.captures = captures
        self.deviceConfigurations = deviceConfigurations
        self.sessions = sessions
        self.tracks = tracks
    }

    static func walletRegistrations(_ requests: [WalletRegistrationRequest], deviceId: String) -> V2UploadBundle {
        V2UploadBundle(kind: .walletRegistrations, deviceId: deviceId, walletRegistrations: requests)
    }

    static func captures(_ requests: [TreeCaptureRequest], deviceId: String) -> V2UploadBundle {
        V2UploadBundle(kind: .captures, deviceId: deviceId, captures: requests)
    }

    static func deviceConfigurations(_ requests: [DeviceConfigRequest], deviceId: String) -> V2UploadBundle {
        V2UploadBundle(kind: .deviceConfigurations, deviceId: deviceId, deviceConfigurations: requests)
    }

    static func sessions(_ requests: [SessionRequest], deviceId: String) -> V2UploadBundle {
        V2UploadBundle(kind: .sessions, deviceId: deviceId, sessions: requests)
    }

    static func tracks(_ requests: [TracksRequest], deviceId: String) -> V2UploadBundle {
        V2UploadBundle(kind: .tracks, deviceId: deviceId, tracks: requests)
    }

    enum CodingKeys: String, CodingKey {
        case packFormatVersion = "pack_format_version"
        case deviceId = "device_id"
        case walletRegistrations = "wallet_registrations"
        case captures
        case deviceConfigurations = "device_configurations"
        case sessions
        case tracks
        case messages
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.packFormatVersion, forKey: .packFormatVersion)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(walletRegistrations, forKey: .walletRegistrations)
        try container.encode(captures, forKey: .captures)
        try container.encode(deviceConfigurations, forKey: .deviceConfigurations)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(tracks, forKey: .tracks)
        // Messages are not uploaded by iOS; the key is still written, as on Android.
        try container.encodeNil(forKey: .messages)
    }

    /// Encodes the bundle and derives its id: `md5(json) + suffix`, as on Android.
    func encoded() throws -> EncodedV2Bundle {
        let encoder = JSONEncoder()
        // Sorted keys make the JSON (and so its md5) deterministic.
        // Unescaped slashes match kotlinx.serialization's output for URLs.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw V2UploadBundleError.encodingFailed
        }
        return EncodedV2Bundle(json: json, bundleId: "\(json.md5)\(kind.bundleIdSuffix)")
    }
}

struct EncodedV2Bundle: Equatable, Sendable {
    let json: String
    let bundleId: String
}

enum V2UploadBundleError: Error {
    case encodingFailed
}
