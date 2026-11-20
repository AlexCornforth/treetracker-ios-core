//
//  DeviceConfigurationUploader.swift
//  Treetracker-Core
//

import Foundation
import CoreData

/// Stage 1: uploads the `_deviceConfigs` bundle.
///
/// It runs first so that every session sent later can reference a device configuration
/// the server already has. Check-ins created before v2 have no configuration, so they are
/// linked to the current one here.
@MainActor
final class DeviceConfigurationUploader {

    private let environment: V2UploadEnvironment

    init(environment: V2UploadEnvironment) {
        self.environment = environment
    }

    func upload() async throws {
        try linkSessionsWithoutConfiguration()

        let fetchRequest: NSFetchRequest<DeviceConfiguration> = DeviceConfiguration.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "uploaded == NO AND uuid != nil")
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "loggedAt", ascending: true)]
        let configurations = try environment.fetch(fetchRequest)

        guard !configurations.isEmpty else {
            Logger.log("UPLOAD V2: No device configurations to upload")
            return
        }

        for batch in configurations.chunked(intoBatchesOf: environment.configuration.batchSize) {
            try Task.checkCancellation()
            let requests = batch.compactMap(request(for:))
            let bundle = V2UploadBundle.deviceConfigurations(requests, deviceId: environment.deviceId)
            try await environment.send(
                bundle,
                for: batch.map(\.objectID),
                as: DeviceConfiguration.self,
                recordBundleId: { $0.bundleId = $1 },
                markUploaded: { $0.uploaded = true }
            )
        }
    }
}

private extension DeviceConfigurationUploader {

    func linkSessionsWithoutConfiguration() throws {
        let fetchRequest: NSFetchRequest<PlanterIdentification> = PlanterIdentification.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "deviceConfiguration == nil AND sessionUploaded == NO")
        let sessions = try environment.fetch(fetchRequest)
        guard !sessions.isEmpty else {
            return
        }
        let current = environment.deviceConfigurationService.currentDeviceConfiguration()
        sessions.forEach { $0.deviceConfiguration = current }
        try environment.save()
        Logger.log("UPLOAD V2: Linked \(sessions.count) earlier check-ins to the current device configuration")
    }

    func request(for configuration: DeviceConfiguration) -> DeviceConfigRequest? {
        guard let uuid = configuration.uuid else {
            return nil
        }
        let deviceInfo = environment.deviceInfoProvider
        return DeviceConfigRequest(
            configurationId: uuid,
            deviceIdentifier: deviceInfo.deviceId,
            appVersion: configuration.appVersion ?? "",
            appBuild: configuration.appBuild,
            manufacturer: deviceInfo.manufacturer,
            brand: deviceInfo.manufacturer,
            model: deviceInfo.model,
            hardware: deviceInfo.machineName,
            device: deviceInfo.machineName,
            osVersion: configuration.osVersion ?? "",
            sdkVersion: configuration.sdkVersion,
            loggedAt: configuration.loggedAt ?? Date()
        )
    }
}
