//
//  DeviceConfigRequest.swift
//  Treetracker-Core
//

import Foundation

/// A device configuration in the v2 upload pack (`device_configurations[]`).
/// Mirrors Android's `DeviceConfigRequest`.
struct DeviceConfigRequest: Encodable, Equatable, Sendable {
    let configurationId: String
    let deviceIdentifier: String
    let appVersion: String
    let appBuild: Int64
    let manufacturer: String
    let brand: String
    let model: String
    let hardware: String
    let device: String
    let serial: String
    let osVersion: String
    /// The major iOS version. Android sends its API level here.
    let sdkVersion: Int64
    /// Android sends its Firebase Installations ID. iOS has no equivalent, so this is empty (as in v1).
    let instanceId: String
    let loggedAt: String

    init(
        configurationId: String,
        deviceIdentifier: String,
        appVersion: String,
        appBuild: Int64,
        manufacturer: String,
        brand: String,
        model: String,
        hardware: String,
        device: String,
        serial: String = "unknown",
        osVersion: String,
        sdkVersion: Int64,
        instanceId: String = "",
        loggedAt: Date
    ) {
        self.configurationId = configurationId
        self.deviceIdentifier = deviceIdentifier
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.manufacturer = manufacturer
        self.brand = brand
        self.model = model
        self.hardware = hardware
        self.device = device
        self.serial = serial
        self.osVersion = osVersion
        self.sdkVersion = sdkVersion
        self.instanceId = instanceId
        self.loggedAt = V2DateFormatter.string(from: loggedAt)
    }

    enum CodingKeys: String, CodingKey {
        case configurationId = "id"
        case deviceIdentifier = "device_identifier"
        case appVersion = "app_version"
        case appBuild = "app_build"
        case manufacturer
        case brand
        case model
        case hardware
        case device
        case serial
        case osVersion = "os_version"
        case sdkVersion = "sdk_version"
        case instanceId = "instance_id"
        case loggedAt = "logged_at"
    }
}
