//
//  MigrationTests.swift
//  Treetracker-CoreTests
//
//  Version 1 stores already on phones must open with model version 2, and their
//  pending data must upload through v2.
//

import Foundation
import CoreData
import Testing
@testable import Treetracker_Core

@Suite("Core Data migration v1 → v2")
@MainActor
struct MigrationTests {

    private static func model(named name: String) throws -> NSManagedObjectModel {
        let bundle = Bundle(for: CoreDataManager.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "mom", subdirectory: "TreeTracker.momd"))
        return try #require(NSManagedObjectModel(contentsOf: url))
    }

    @Test func currentModelIsVersion2() throws {
        let version2 = try Self.model(named: "TreeTracker 2")
        #expect(CoreDataManager.model.entityVersionHashesByName == version2.entityVersionHashesByName)
        #expect(CoreDataManager.model.entitiesByName["DeviceConfiguration"] != nil)
    }

    @Test func lightweightMigrationCanBeInferred() throws {
        let version1 = try Self.model(named: "TreeTracker")
        let version2 = try Self.model(named: "TreeTracker 2")
        let mapping = try? NSMappingModel.inferredMappingModel(forSourceModel: version1, destinationModel: version2)
        #expect(mapping != nil)
    }

    @Test func version1StoreMigratesAndUploadsThroughV2() async throws {
        // 1. Create a store with the version 1 model and seed pending data, the way the
        //    App Store build would have left it.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("TreeTracker.sqlite")

        let checkInUUID = UUID().uuidString
        let treeUUID = UUID().uuidString
        let planterUUID = UUID().uuidString

        do {
            let version1 = try Self.model(named: "TreeTracker")
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: version1)
            let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: nil)
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator

            let planter = NSEntityDescription.insertNewObject(forEntityName: "PlanterDetail", into: context)
            planter.setValue(planterUUID, forKey: "uuid")
            planter.setValue("planter@example.org", forKey: "identifier")
            planter.setValue("Ada", forKey: "firstName")
            planter.setValue("Planter", forKey: "lastName")
            planter.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "createdAt")
            planter.setValue(true, forKey: "uploaded") // registered under v1

            let checkIn = NSEntityDescription.insertNewObject(forEntityName: "PlanterIdentification", into: context)
            checkIn.setValue(checkInUUID, forKey: "uuid")
            checkIn.setValue(Date(timeIntervalSince1970: 1_700_000_100), forKey: "createdAt")
            checkIn.setValue("https://images.example.invalid/selfie.jpg", forKey: "photoURL")
            checkIn.setValue(planter, forKey: "planter")

            let tree = NSEntityDescription.insertNewObject(forEntityName: "TreeCapture", into: context)
            tree.setValue(treeUUID, forKey: "uuid")
            tree.setValue(Date(timeIntervalSince1970: 1_700_000_200), forKey: "createdAt")
            tree.setValue("tree-\(treeUUID)", forKey: "localPhotoPath")
            tree.setValue(false, forKey: "uploaded")
            tree.setValue(checkIn, forKey: "planterIdentification")

            let uploadedTree = NSEntityDescription.insertNewObject(forEntityName: "TreeCapture", into: context)
            uploadedTree.setValue(UUID().uuidString, forKey: "uuid")
            uploadedTree.setValue(Date(timeIntervalSince1970: 1_600_000_000), forKey: "createdAt")
            uploadedTree.setValue("https://images.example.invalid/old.jpg", forKey: "photoURL")
            uploadedTree.setValue(true, forKey: "uploaded") // already sent by v1
            uploadedTree.setValue(checkIn, forKey: "planterIdentification")

            let location = NSEntityDescription.insertNewObject(forEntityName: "LocationDataEntity", into: context)
            location.setValue(checkInUUID, forKey: "planterCheckInId")
            location.setValue(treeUUID, forKey: "treeUUID")
            location.setValue(Date(timeIntervalSince1970: 1_700_000_150), forKey: "capturedAt")
            location.setValue("CONVERGED", forKey: "convergenceStatus")
            location.setValue(false, forKey: "uploaded")

            try context.save()
            try coordinator.remove(store)
        }

        // 2. Open it the way the app does, with the current model and automatic migration.
        let store = TestStore(existingStoreAt: storeURL)
        store.documents.existingFiles.insert("tree-\(treeUUID)")

        let planters = try store.fetchAll(PlanterDetail.self, "PlanterDetail")
        let trees = try store.fetchAll(TreeCapture.self, "TreeCapture")
        let checkIns = try store.fetchAll(PlanterIdentification.self, "PlanterIdentification")
        #expect(planters.count == 1)
        #expect(trees.count == 2)
        #expect(planters.first?.walletRegistrationUploaded == false)
        #expect(checkIns.first?.sessionUploaded == false)
        #expect(checkIns.first?.deviceConfiguration == nil)

        // 3. Upload through v2 and check the payload chain.
        let bundles = RecordingBundleUploader()
        let images = RecordingImageUploader()
        let pipeline = V2UploadPipeline(
            environment: store.makeEnvironment(bundleUploader: bundles, imageUploader: images),
            currentPlanterIdentifier: nil,
            onProgress: { _ in }
        )
        try await pipeline.run()

        let kinds = await bundles.uploads.map(\.kind)
        #expect(kinds == ["_deviceConfigs", "_registrations", "_sessions", "_captures", "_tracks"])

        let registrationBundle = try #require(await bundles.uploads(ofKind: "_registrations").first)
        let registration = try #require((registrationBundle.object["wallet_registrations"] as? [[String: Any]])?.first)
        #expect(registration["id"] as? String == planterUUID)

        let sessionBundle = try #require(await bundles.uploads(ofKind: "_sessions").first)
        let session = try #require((sessionBundle.object["sessions"] as? [[String: Any]])?.first)
        #expect(session["id"] as? String == checkInUUID)
        #expect(session["originating_wallet_registration_id"] as? String == planterUUID)

        let captureBundle = try #require(await bundles.uploads(ofKind: "_captures").first)
        let captures = try #require(captureBundle.object["captures"] as? [[String: Any]])
        #expect(captures.count == 1, "the tree v1 already uploaded is not sent again")
        #expect(captures.first?["id"] as? String == treeUUID)
        #expect(captures.first?["session_id"] as? String == checkInUUID)

        let trackBundle = try #require(await bundles.uploads(ofKind: "_tracks").first)
        let track = try #require((trackBundle.object["tracks"] as? [[String: Any]])?.first)
        #expect(track["sessionId"] as? String == checkInUUID)
    }
}
