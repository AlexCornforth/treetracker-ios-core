//
//  V2UploadPipelineTests.swift
//  Treetracker-CoreTests
//
//  The v2 pipeline against fake S3, covering the offline-first cases: a long backlog,
//  flaky photos, dropped connections and stopping part-way.
//

import Foundation
import CoreData
import Testing
@testable import Treetracker_Core

@Suite("v2 upload pipeline")
@MainActor
struct V2UploadPipelineTests {

    // MARK: Helpers

    private struct Fixture {
        let store: TestStore
        let planter: PlanterDetail
        let checkIn: PlanterIdentification
        let trees: [TreeCapture]
    }

    private func makeFixture(trees count: Int, locations: Int = 1) throws -> Fixture {
        let store = TestStore()
        let planter = store.makePlanter()
        let checkIn = store.makeCheckIn(planter: planter)
        let trees = (0..<count).map { index in
            store.makeTree(checkIn: checkIn, createdAt: Date(timeIntervalSince1970: 1_700_000_200 + Double(index)))
        }
        (0..<locations).forEach { _ in store.makeLocation(checkIn: checkIn) }
        try store.save()
        return Fixture(store: store, planter: planter, checkIn: checkIn, trees: trees)
    }

    private func makePipeline(
        _ store: TestStore,
        bundles: RecordingBundleUploader,
        images: RecordingImageUploader,
        imageReader: FakeImageReader = FakeImageReader(),
        currentPlanterIdentifier: String? = nil,
        onProgress: @escaping (UploadProgress) -> Void = { _ in }
    ) -> V2UploadPipeline {
        V2UploadPipeline(
            environment: store.makeEnvironment(bundleUploader: bundles, imageUploader: images, imageReader: imageReader),
            currentPlanterIdentifier: currentPlanterIdentifier,
            onProgress: onProgress
        )
    }

    private func pendingTreeCount(_ store: TestStore) throws -> Int {
        let request: NSFetchRequest<TreeCapture> = TreeCapture.fetchRequest()
        request.predicate = NSPredicate(format: "uploaded == NO")
        return try store.context.count(for: request)
    }

    // MARK: Happy path

    @Test func uploadsEveryStageInAndroidOrder() async throws {
        let fixture = try makeFixture(trees: 3)
        let bundles = RecordingBundleUploader()
        let images = RecordingImageUploader()

        try await makePipeline(fixture.store, bundles: bundles, images: images).run()

        #expect(await bundles.uploads.map(\.kind) == ["_deviceConfigs", "_registrations", "_sessions", "_captures", "_tracks"])
        #expect(fixture.planter.walletRegistrationUploaded)
        #expect(fixture.checkIn.sessionUploaded)
        #expect(fixture.checkIn.deviceConfiguration?.uploaded == true)
        #expect(fixture.trees.allSatisfy { $0.uploaded && $0.photoURL != nil && $0.bundleId?.hasSuffix("_captures") == true })
        #expect(try fixture.store.fetchAll(LocationDataEntity.self, "LocationDataEntity").isEmpty, "uploaded locations are deleted")
    }

    @Test func deletesLocalTreePhotosButKeepsTheCurrentPlantersSelfie() async throws {
        let store = TestStore()
        let current = store.makePlanter(identifier: "current@example.org")
        let other = store.makePlanter(identifier: "other@example.org")
        let currentCheckIn = store.makeCheckIn(planter: current)
        let otherCheckIn = store.makeCheckIn(planter: other)
        let tree = store.makeTree(checkIn: otherCheckIn)
        let treePhoto = try #require(tree.localPhotoPath)
        let currentSelfie = try #require(currentCheckIn.localPhotoPath)
        let otherSelfie = try #require(otherCheckIn.localPhotoPath)
        try store.save()

        try await makePipeline(store, bundles: RecordingBundleUploader(), images: RecordingImageUploader(), currentPlanterIdentifier: "current@example.org").run()

        #expect(store.documents.removedFiles.contains(treePhoto))
        #expect(tree.localPhotoPath == nil)
        #expect(store.documents.removedFiles.contains(otherSelfie))
        #expect(!store.documents.removedFiles.contains(currentSelfie))
        #expect(currentCheckIn.localPhotoPath == currentSelfie)
    }

    @Test func treesAlreadyUploadedByV1AreNotSentAgain() async throws {
        let store = TestStore()
        let planter = store.makePlanter()
        let oldCheckIn = store.makeCheckIn(planter: planter, photoURL: "https://images.example.invalid/old.jpg")
        store.makeTree(checkIn: oldCheckIn, uploaded: true, photoURL: "https://images.example.invalid/t.jpg")
        let newCheckIn = store.makeCheckIn(planter: planter, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let pending = store.makeTree(checkIn: newCheckIn)
        try store.save()
        let bundles = RecordingBundleUploader()

        try await makePipeline(store, bundles: bundles, images: RecordingImageUploader()).run()

        let sessions = try #require(await bundles.uploads(ofKind: "_sessions").first?.object["sessions"] as? [[String: Any]])
        #expect(sessions.map { $0["id"] as? String } == [newCheckIn.uuid], "fully uploaded v1 sessions are not re-sent")
        let captures = try #require(await bundles.uploads(ofKind: "_captures").first?.object["captures"] as? [[String: Any]])
        #expect(captures.map { $0["id"] as? String } == [pending.uuid])
        #expect(!oldCheckIn.sessionUploaded)
    }

    // MARK: Ordering and failure

    @Test func sessionFailureMeansNoCapturesAreSent() async throws {
        let fixture = try makeFixture(trees: 2)
        let bundles = RecordingBundleUploader()
        await bundles.failWhen { kind, _ in kind == "_sessions" ? TestNetworkError.forbidden : nil }

        await #expect(throws: (any Error).self) {
            try await makePipeline(fixture.store, bundles: bundles, images: RecordingImageUploader()).run()
        }

        #expect(await bundles.uploads(ofKind: "_captures").isEmpty)
        #expect(!(await bundles.attemptedKinds.contains("_captures")))
        #expect(fixture.trees.allSatisfy { !$0.uploaded })
    }

    @Test func bundleIdIsWrittenBeforeThePutAndUploadedOnlyAfterIt() async throws {
        let fixture = try makeFixture(trees: 2)
        let bundles = RecordingBundleUploader()
        await bundles.failWhen { kind, _ in kind == "_captures" ? TestNetworkError.forbidden : nil }

        await #expect(throws: UploadError.self) {
            try await makePipeline(fixture.store, bundles: bundles, images: RecordingImageUploader()).run()
        }

        #expect(fixture.trees.allSatisfy { $0.bundleId?.hasSuffix("_captures") == true }, "bundle id recorded before the upload")
        #expect(fixture.trees.allSatisfy { !$0.uploaded }, "not marked uploaded when the put failed")
        #expect(fixture.trees.allSatisfy { $0.photoURL != nil }, "photo URLs are kept for the next run")
    }

    // MARK: Bad connections

    @Test func oneFailedPhotoDoesNotHoldBackTheRestOfTheBatch() async throws {
        let fixture = try makeFixture(trees: 50)
        let failingUUID = try #require(fixture.trees[7].uuid)
        let bundles = RecordingBundleUploader()
        let images = RecordingImageUploader()
        await images.failWhen { uuid, _ in uuid == failingUUID ? TestNetworkError.forbidden : nil }

        do {
            try await makePipeline(fixture.store, bundles: bundles, images: images).run()
            Issue.record("Expected a partial failure")
        } catch UploadError.partialFailure(let failedTrees) {
            #expect(failedTrees == 1)
        }

        let captures = try #require(await bundles.uploads(ofKind: "_captures").first?.object["captures"] as? [[String: Any]])
        #expect(captures.count == 49)
        #expect(!fixture.trees[7].uploaded)
        #expect(fixture.trees.filter(\.uploaded).count == 49)
        #expect(try pendingTreeCount(fixture.store) == 1)
    }

    @Test func transientErrorsAreRetriedTwice() async throws {
        let fixture = try makeFixture(trees: 1)
        let uuid = try #require(fixture.trees[0].uuid)
        let images = RecordingImageUploader()
        await images.failWhen { _, attempt in attempt <= 2 ? TestNetworkError.timedOut : nil }
        let bundles = RecordingBundleUploader()
        await bundles.failWhen { kind, attempt in kind == "_captures" && attempt == 1 ? TestNetworkError.timedOut : nil }

        try await makePipeline(fixture.store, bundles: bundles, images: images).run()

        #expect(await images.attemptsByUUID[uuid] == 3)
        #expect(await bundles.attemptedKinds.filter { $0 == "_captures" }.count == 2)
        #expect(fixture.trees[0].uploaded)
    }

    @Test func nonTransientErrorsAreNotRetried() async throws {
        let fixture = try makeFixture(trees: 1)
        fixture.checkIn.photoURL = "https://images.example.invalid/selfie.jpg"
        try fixture.store.save()
        let uuid = try #require(fixture.trees[0].uuid)
        let images = RecordingImageUploader()
        await images.failWhen { _, _ in TestNetworkError.forbidden }

        await #expect(throws: UploadError.self) {
            try await makePipeline(fixture.store, bundles: RecordingBundleUploader(), images: images).run()
        }
        #expect(await images.attemptsByUUID[uuid] == 1)
    }

    @Test func runStopsAsSoonAsTheDeviceIsOffline() async throws {
        let fixture = try makeFixture(trees: 120)
        // The selfie is already up, so the connection drops during the first batch of tree photos.
        fixture.checkIn.photoURL = "https://images.example.invalid/selfie.jpg"
        try fixture.store.save()
        let images = RecordingImageUploader()
        await images.failWhen { _, _ in TestNetworkError.notConnected }
        let bundles = RecordingBundleUploader()

        do {
            try await makePipeline(fixture.store, bundles: bundles, images: images).run()
            Issue.record("Expected notConnected")
        } catch UploadError.notConnected {
            // Expected.
        }

        #expect(await bundles.attemptedKinds.contains("_captures") == false)
        #expect(await bundles.attemptedKinds.contains("_tracks") == false, "later stages don't run")
        #expect(await images.attemptsByUUID.count == 50, "only the first batch of photos was tried")
        #expect(try pendingTreeCount(fixture.store) == 120)
    }

    @Test func runStopsAfterThreeBatchesInARowUploadNothing() async throws {
        let fixture = try makeFixture(trees: 250)
        let bundles = RecordingBundleUploader()
        await bundles.failWhen { kind, _ in kind == "_captures" ? TestNetworkError.forbidden : nil }

        do {
            try await makePipeline(fixture.store, bundles: bundles, images: RecordingImageUploader()).run()
            Issue.record("Expected repeatedBatchFailures")
        } catch UploadError.repeatedBatchFailures {
            // Expected.
        }

        #expect(await bundles.attemptedKinds.filter { $0 == "_captures" }.count == 3)
        #expect(try pendingTreeCount(fixture.store) == 250)
    }

    @Test func atMostFourPhotosUploadAtOnce() async throws {
        let fixture = try makeFixture(trees: 30)
        let images = RecordingImageUploader()

        try await makePipeline(fixture.store, bundles: RecordingBundleUploader(), images: images).run()

        let maxInFlight = await images.maxInFlight
        #expect(maxInFlight <= 4)
        #expect(maxInFlight > 1, "photos do upload in parallel")
    }

    @Test func missingLocalPhotoLeavesOnlyThatTreePending() async throws {
        let fixture = try makeFixture(trees: 3)
        let missing = try #require(fixture.trees[1].localPhotoPath)

        await #expect(throws: UploadError.self) {
            try await makePipeline(
                fixture.store,
                bundles: RecordingBundleUploader(),
                images: RecordingImageUploader(),
                imageReader: FakeImageReader(missingFiles: [missing])
            ).run()
        }
        #expect(fixture.trees.filter(\.uploaded).count == 2)
    }

    // MARK: Large backlog

    @Test func largeBacklogUploadsInBatchesOfFiftyWithSteadyProgress() async throws {
        let fixture = try makeFixture(trees: 2_000)
        let context = fixture.store.context
        context.reset() // start like a fresh launch, with nothing loaded in memory
        let bundles = RecordingBundleUploader()
        var progress: [UploadProgress] = []
        var largestLoadedBatch = 0

        try await makePipeline(fixture.store, bundles: bundles, images: RecordingImageUploader()) { update in
            progress.append(update)
            let loadedTrees = context.registeredObjects.filter { $0 is TreeCapture && !$0.isFault }.count
            largestLoadedBatch = max(largestLoadedBatch, loadedTrees)
        }.run()

        #expect(await bundles.uploads(ofKind: "_captures").count == 40)
        #expect(progress.first == UploadProgress(uploadedTrees: 0, totalTrees: 2_000))
        #expect(progress.last == UploadProgress(uploadedTrees: 2_000, totalTrees: 2_000))
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.uploadedTrees <= $1.uploadedTrees })
        #expect(largestLoadedBatch <= 50, "only one batch of trees is in memory at a time")
        #expect(try pendingTreeCount(fixture.store) == 0)
    }

    // MARK: Gating

    @Test func plantersWithoutAnUploadedSelfieWaitForTheNextRun() async throws {
        let fixture = try makeFixture(trees: 2)
        let selfieUUID = try #require(fixture.checkIn.uuid)
        let images = RecordingImageUploader()
        await images.failWhen { uuid, _ in uuid == selfieUUID ? TestNetworkError.forbidden : nil }
        let bundles = RecordingBundleUploader()

        do {
            try await makePipeline(fixture.store, bundles: bundles, images: images).run()
            Issue.record("Expected a partial failure")
        } catch UploadError.partialFailure(let failedTrees) {
            #expect(failedTrees == 2)
        }

        #expect(await bundles.uploads(ofKind: "_registrations").isEmpty)
        #expect(await bundles.uploads(ofKind: "_sessions").isEmpty)
        #expect(await bundles.uploads(ofKind: "_captures").isEmpty)

        // Next press, with the connection working: everything goes.
        await images.failWhen { _, _ in nil }
        try await makePipeline(fixture.store, bundles: bundles, images: images).run()
        #expect(fixture.trees.allSatisfy(\.uploaded))
    }
}
