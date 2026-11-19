//
//  AsyncUploadManager.swift
//  Treetracker-Core
//

import Foundation
import UIKit

/// Keeps an upload going while a planter waits for a long backlog to finish.
@MainActor
protocol UploadKeepAlive: AnyObject {
    func begin()
    func end()
}

/// Keeps the screen awake while uploading, and asks iOS for background time so the
/// current batch can finish if the app is sent to the background. A run stopped by iOS
/// loses nothing; the next press carries on.
@MainActor
final class ApplicationUploadKeepAlive: UploadKeepAlive {

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var previousIdleTimerDisabled = false
    private var isActive = false

    nonisolated init() {}

    func begin() {
        guard !isActive else {
            return
        }
        isActive = true
        let application = UIApplication.shared
        previousIdleTimerDisabled = application.isIdleTimerDisabled
        application.isIdleTimerDisabled = true
        backgroundTask = application.beginBackgroundTask(withName: "TreetrackerUpload") { [weak self] in
            // iOS calls the expiration handler on the main thread.
            MainActor.assumeIsolated {
                self?.endBackgroundTask()
            }
        }
    }

    func end() {
        guard isActive else {
            return
        }
        isActive = false
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

/// Runs v2 uploads with Swift concurrency. Replaces `UploadManager` when the SDK is
/// configured with `uploadFormat: .v2`; the v1 `UploadManager` is unchanged.
///
/// - Starting while a run is in progress does nothing, so two runs never overlap.
/// - `stopUploading()` cancels the run, including any S3 request in flight. `isUploading`
///   stays true until the run has really ended.
/// - Errors other than cancellation reach `uploadManager(_:didError:)`.
///
/// `@preconcurrency` conformance: `UploadManaging` is not actor-isolated, but its callers
/// (the app's view models) always use it on the main thread, as they do with the v1 manager.
/// The conformance checks that at runtime. Removal plan: drop it when `UploadManaging`
/// becomes `@MainActor` (a public API change) or the project adopts isolated conformances (Swift 6.2).
@MainActor
final class AsyncUploadManager: @preconcurrency UploadManaging {

    typealias PipelineFactory = @MainActor (
        _ currentPlanterIdentifier: String?,
        _ onProgress: @escaping (UploadProgress) -> Void
    ) -> V2UploadPipeline

    weak var delegate: UploadManagerDelegate?
    private(set) var isUploading: Bool = false

    private var uploadTask: Task<Void, Never>?
    private let makePipeline: PipelineFactory
    private let keepAlive: UploadKeepAlive

    nonisolated init(keepAlive: UploadKeepAlive, makePipeline: @escaping PipelineFactory) {
        self.keepAlive = keepAlive
        self.makePipeline = makePipeline
    }

    func startUploading(currentPlanter: Planter) {
        guard uploadTask == nil else {
            return
        }

        Logger.log("AsyncUploadManager: Uploads started")
        isUploading = true
        keepAlive.begin()
        delegate?.uploadManagerDidStartUploadingTrees(self)

        let pipeline = makePipeline(currentPlanter.identifier) { [weak self] progress in
            guard let self = self else {
                return
            }
            self.delegate?.uploadManager(self, didUpdateProgress: progress)
        }

        // Inherits the main actor: the code around the await updates UI-facing state.
        uploadTask = Task { [weak self] in
            var failure: Error?
            do {
                try await pipeline.run()
            } catch {
                // Cancelling can also surface as an AWS "cancelled" network error.
                if !(error is CancellationError) && !Task.isCancelled {
                    failure = error
                }
            }
            self?.finishUploading(error: failure)
        }
    }

    func stopUploading() {
        guard let uploadTask = uploadTask else {
            return
        }
        Logger.log("AsyncUploadManager: Stopping uploads")
        uploadTask.cancel()
    }

    /// Waits for the current run to finish. Used by tests.
    func waitUntilFinished() async {
        await uploadTask?.value
    }
}

private extension AsyncUploadManager {

    func finishUploading(error: Error?) {
        uploadTask = nil
        isUploading = false
        keepAlive.end()
        if let error = error {
            Logger.log("AsyncUploadManager: Uploads failed: \(error)")
            delegate?.uploadManager(self, didError: error)
        } else {
            Logger.log("AsyncUploadManager: Uploads finished")
        }
        delegate?.uploadManagerDidStopUploadingTrees(self)
    }
}
