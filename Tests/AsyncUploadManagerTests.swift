//
//  AsyncUploadManagerTests.swift
//  Treetracker-CoreTests
//

import Foundation
import Testing
@testable import Treetracker_Core

@Suite("Async upload manager")
@MainActor
struct AsyncUploadManagerTests {

    private func makeManager(
        store: TestStore,
        bundles: RecordingBundleUploader,
        images: RecordingImageUploader = RecordingImageUploader(),
        keepAlive: FakeKeepAlive = FakeKeepAlive()
    ) -> AsyncUploadManager {
        AsyncUploadManager(keepAlive: keepAlive) { currentPlanterIdentifier, onProgress in
            V2UploadPipeline(
                environment: store.makeEnvironment(bundleUploader: bundles, imageUploader: images),
                currentPlanterIdentifier: currentPlanterIdentifier,
                onProgress: onProgress
            )
        }
    }

    private func seed(_ store: TestStore) throws -> (PlanterDetail, TreeCapture) {
        let planter = store.makePlanter()
        let checkIn = store.makeCheckIn(planter: planter)
        let tree = store.makeTree(checkIn: checkIn)
        try store.save()
        return (planter, tree)
    }

    @Test func successfulRunReportsStartProgressAndStop() async throws {
        let store = TestStore()
        let (planter, tree) = try seed(store)
        let keepAlive = FakeKeepAlive()
        let manager = makeManager(store: store, bundles: RecordingBundleUploader(), keepAlive: keepAlive)
        let spy = UploadDelegateSpy()
        manager.delegate = spy

        manager.startUploading(currentPlanter: planter)
        #expect(manager.isUploading)
        await manager.waitUntilFinished()

        #expect(!manager.isUploading)
        #expect(spy.started == 1)
        #expect(spy.stopped == 1)
        #expect(spy.errors.isEmpty)
        #expect(spy.progress.last == UploadProgress(uploadedTrees: 1, totalTrees: 1))
        #expect(tree.uploaded)
        #expect(keepAlive.beginCount == 1)
        #expect(keepAlive.endCount == 1)
    }

    @Test func failedPutIsReportedAndUploadingResets() async throws {
        let store = TestStore()
        let (planter, _) = try seed(store)
        let bundles = RecordingBundleUploader()
        await bundles.failWhen { _, _ in AWSS3AsyncUploaderError.requestCreationFailed }
        let manager = makeManager(store: store, bundles: bundles)
        let spy = UploadDelegateSpy()
        manager.delegate = spy

        manager.startUploading(currentPlanter: planter)
        await manager.waitUntilFinished()

        #expect(!manager.isUploading)
        #expect(spy.errors.count == 1)
        #expect(spy.stopped == 1)
    }

    @Test func startingTwiceDoesNotOverlapRuns() async throws {
        let store = TestStore()
        let (planter, _) = try seed(store)
        let bundles = RecordingBundleUploader()
        let manager = makeManager(store: store, bundles: bundles)
        let spy = UploadDelegateSpy()
        manager.delegate = spy

        manager.startUploading(currentPlanter: planter)
        manager.startUploading(currentPlanter: planter)
        await manager.waitUntilFinished()

        #expect(spy.started == 1)
        #expect(await bundles.attemptedKinds.filter { $0 == "_captures" }.count == 1)
    }

    @Test func stoppingCancelsAtTheNextStageAndMarksNothingUploaded() async throws {
        let store = TestStore()
        let (planter, tree) = try seed(store)
        let bundles = RecordingBundleUploader()
        await bundles.suspendUntilCancelled(kind: "_sessions")
        let manager = makeManager(store: store, bundles: bundles)
        let spy = UploadDelegateSpy()
        manager.delegate = spy

        manager.startUploading(currentPlanter: planter)
        // Let the run reach the suspended sessions upload.
        while await !bundles.attemptedKinds.contains("_sessions") {
            await Task.yield()
        }
        manager.stopUploading()
        #expect(manager.isUploading, "stays true until the run has really ended")
        await manager.waitUntilFinished()

        #expect(!manager.isUploading)
        #expect(spy.errors.isEmpty, "stopping is not an error")
        #expect(spy.stopped == 1)
        #expect(!(await bundles.attemptedKinds.contains("_captures")))
        #expect(!tree.uploaded)
        #expect(tree.planterIdentification?.sessionUploaded == false)
    }
}
