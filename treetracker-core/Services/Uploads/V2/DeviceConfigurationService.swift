//
//  DeviceConfigurationService.swift
//  Treetracker-Core
//

import Foundation
import CoreData

/// Provides the `DeviceConfiguration` row for the app and OS versions running now.
///
/// Mirrors Android's `DeviceConfigUpdater`: a new row is created whenever the app version,
/// app build or OS version changes, so each v2 session records the configuration it ran on.
/// Like the rest of the persistence layer, call it on the main thread (it uses `viewContext`).
protocol DeviceConfigurationProviding {
    /// Returns the current configuration, inserting a new one if anything changed.
    /// The caller saves the context.
    func currentDeviceConfiguration() -> DeviceConfiguration
}

final class DeviceConfigurationService: DeviceConfigurationProviding {

    private let coreDataManager: CoreDataManaging
    private let deviceInfoProvider: DeviceInfoProviding
    private let appBundleInfoProvider: AppBundleInfoProviding
    private let now: () -> Date

    init(
        coreDataManager: CoreDataManaging,
        deviceInfoProvider: DeviceInfoProviding = DeviceInfoProvider(),
        appBundleInfoProvider: AppBundleInfoProviding = AppBundleInfoProvider(),
        now: @escaping () -> Date = Date.init
    ) {
        self.coreDataManager = coreDataManager
        self.deviceInfoProvider = deviceInfoProvider
        self.appBundleInfoProvider = appBundleInfoProvider
        self.now = now
    }

    func currentDeviceConfiguration() -> DeviceConfiguration {
        let appVersion = appBundleInfoProvider.versionNumber
        let appBuild = Int64(appBundleInfoProvider.buildNumber) ?? 0
        let osVersion = deviceInfoProvider.systemVersion

        if let latest = latestConfiguration(),
           latest.appVersion == appVersion,
           latest.appBuild == appBuild,
           latest.osVersion == osVersion {
            return latest
        }

        let configuration = DeviceConfiguration(context: coreDataManager.viewContext)
        configuration.uuid = UUID().uuidString
        configuration.appVersion = appVersion
        configuration.appBuild = appBuild
        configuration.osVersion = osVersion
        configuration.sdkVersion = Self.majorVersion(of: osVersion)
        configuration.loggedAt = now()
        configuration.uploaded = false
        return configuration
    }

    /// The iOS major version, sent as `sdk_version` (Android sends its API level there).
    static func majorVersion(of osVersion: String) -> Int64 {
        Int64(osVersion.split(separator: ".").first ?? "") ?? 0
    }
}

private extension DeviceConfigurationService {

    func latestConfiguration() -> DeviceConfiguration? {
        let fetchRequest: NSFetchRequest<DeviceConfiguration> = DeviceConfiguration.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "loggedAt", ascending: false)]
        fetchRequest.fetchLimit = 1
        return coreDataManager.perform(fetchRequest: fetchRequest)?.first
    }
}
