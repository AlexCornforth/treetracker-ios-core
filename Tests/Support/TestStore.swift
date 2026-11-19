//
//  TestStore.swift
//  Treetracker-CoreTests
//

import Foundation
import CoreData
@testable import Treetracker_Core

/// A real SQLite store in a temporary folder, using the shared `CoreDataManager.model`.
///
/// Objects are inserted by entity name, so they resolve against this context's model even
/// when a test has also loaded the version 1 model.
@MainActor
final class TestStore {

    let directory: URL
    let coreDataManager: CoreDataManager
    let documents = FakeDocumentManager()

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TreetrackerCoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("TreeTracker.sqlite"))
        coreDataManager = CoreDataManager(storeDescription: description)
    }

    /// Opens an existing store file, for example one created with the version 1 model.
    init(existingStoreAt url: URL) {
        directory = url.deletingLastPathComponent()
        coreDataManager = CoreDataManager(storeDescription: NSPersistentStoreDescription(url: url))
    }

    var context: NSManagedObjectContext { coreDataManager.viewContext }

    func save() throws {
        try context.save()
    }

    // MARK: Seeding

    @discardableResult
    func makePlanter(identifier: String = "planter@example.org", walletRegistrationUploaded: Bool = false) -> PlanterDetail {
        let planter = insert(PlanterDetail.self, "PlanterDetail")
        planter.uuid = UUID().uuidString
        planter.identifier = identifier
        planter.firstName = "Ada"
        planter.lastName = "Planter"
        planter.email = identifier
        planter.organization = "Greenstand"
        planter.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        planter.latitude = -3.38
        planter.longitude = 36.68
        planter.uploaded = false
        planter.walletRegistrationUploaded = walletRegistrationUploaded
        return planter
    }

    @discardableResult
    func makeCheckIn(planter: PlanterDetail, photoURL: String? = nil, createdAt: Date = Date(timeIntervalSince1970: 1_700_000_100)) -> PlanterIdentification {
        let checkIn = insert(PlanterIdentification.self, "PlanterIdentification")
        let uuid = UUID().uuidString
        checkIn.uuid = uuid
        checkIn.createdAt = createdAt
        checkIn.localPhotoPath = "selfie-\(uuid)"
        documents.existingFiles.insert("selfie-\(uuid)")
        checkIn.photoURL = photoURL
        checkIn.latitude = -3.38
        checkIn.longitude = 36.68
        checkIn.planter = planter
        return checkIn
    }

    @discardableResult
    func makeTree(checkIn: PlanterIdentification, uploaded: Bool = false, photoURL: String? = nil, createdAt: Date = Date(timeIntervalSince1970: 1_700_000_200)) -> TreeCapture {
        let tree = insert(TreeCapture.self, "TreeCapture")
        let uuid = UUID().uuidString
        tree.uuid = uuid
        tree.createdAt = createdAt
        tree.latitude = -3.3869
        tree.longitude = 36.6830
        tree.horizontalAccuracy = 5
        tree.noteContent = "Grevillea"
        tree.localPhotoPath = "tree-\(uuid)"
        documents.existingFiles.insert("tree-\(uuid)")
        tree.photoURL = photoURL
        tree.uploaded = uploaded
        tree.planterIdentification = checkIn
        return tree
    }

    @discardableResult
    func makeLocation(checkIn: PlanterIdentification, uploaded: Bool = false) -> LocationDataEntity {
        let location = insert(LocationDataEntity.self, "LocationDataEntity")
        location.planterCheckInId = checkIn.uuid
        location.treeUUID = UUID().uuidString
        location.capturedAt = Date(timeIntervalSince1970: 1_700_000_150)
        location.latitude = -3.3869
        location.longitude = 36.6830
        location.accuracy = 4.5
        location.convergenceStatus = ConvergenceStatus.converged.rawValue
        location.uploaded = uploaded
        return location
    }

    func fetchAll<T: NSManagedObject>(_ type: T.Type, _ entityName: String) throws -> [T] {
        let request = NSFetchRequest<T>(entityName: entityName)
        return try context.fetch(request)
    }

    // MARK: Environment

    func makeEnvironment(
        bundleUploader: V2BundleUploading,
        imageUploader: AsyncImageUploading,
        imageReader: ImageDataReading = FakeImageReader(),
        configuration: V2UploadConfiguration = .test,
        deviceInfo: FakeDeviceInfoProvider = FakeDeviceInfoProvider(),
        appInfo: FakeAppBundleInfoProvider = FakeAppBundleInfoProvider()
    ) -> V2UploadEnvironment {
        V2UploadEnvironment(
            coreDataManager: coreDataManager,
            documentManager: documents,
            bundleUploader: bundleUploader,
            imageUploader: imageUploader,
            imageReader: imageReader,
            deviceConfigurationService: DeviceConfigurationService(
                coreDataManager: coreDataManager,
                deviceInfoProvider: deviceInfo,
                appBundleInfoProvider: appInfo
            ),
            deviceInfoProvider: deviceInfo,
            configuration: configuration
        )
    }

    private func insert<T: NSManagedObject>(_ type: T.Type, _ entityName: String) -> T {
        // swiftlint:disable:next force_cast
        NSEntityDescription.insertNewObject(forEntityName: entityName, into: context) as! T
    }
}

extension V2UploadConfiguration {
    /// Production limits with no waiting between retries.
    static var test: V2UploadConfiguration {
        var configuration = V2UploadConfiguration()
        configuration.retryPolicy = RetryPolicy(delays: [0, 0])
        return configuration
    }
}
