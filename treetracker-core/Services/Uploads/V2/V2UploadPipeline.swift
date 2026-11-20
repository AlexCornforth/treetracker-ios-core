//
//  V2UploadPipeline.swift
//  Treetracker-Core
//

import Foundation
import CoreData

/// Runs one v2 upload, with stages in Android's order:
/// device configurations → wallet registrations → sessions → captures → tracks.
///
/// Each stage depends on ids the server got in an earlier stage, so a thrown error stops
/// every later stage. The stages also only select records whose prerequisites have already
/// uploaded, so anything not ready simply waits for the next run. Records are only marked
/// uploaded after their bundle reaches S3, so every stage can safely run again.
@MainActor
final class V2UploadPipeline {

    private let environment: V2UploadEnvironment
    private let deviceConfigurations: DeviceConfigurationUploader
    private let walletRegistrations: WalletRegistrationUploader
    private let sessions: SessionUploader
    private let captures: CaptureUploader
    private let tracks: TrackUploader

    init(
        environment: V2UploadEnvironment,
        currentPlanterIdentifier: String?,
        onProgress: @escaping (UploadProgress) -> Void
    ) {
        self.environment = environment
        self.deviceConfigurations = DeviceConfigurationUploader(environment: environment)
        self.walletRegistrations = WalletRegistrationUploader(environment: environment, currentPlanterIdentifier: currentPlanterIdentifier)
        self.sessions = SessionUploader(environment: environment)
        self.captures = CaptureUploader(environment: environment, onProgress: onProgress)
        self.tracks = TrackUploader(environment: environment)
    }

    func run() async throws {
        Logger.log("UPLOAD V2: Started")

        try await deviceConfigurations.upload()
        try Task.checkCancellation()

        try await walletRegistrations.upload()
        try Task.checkCancellation()

        try await sessions.upload()
        try Task.checkCancellation()

        // Some trees failing doesn't stop the tracks stage. Losing the connection does.
        var captureError: UploadError?
        do {
            try await captures.upload()
        } catch UploadError.partialFailure(let failedTrees) {
            captureError = .partialFailure(failedTrees: failedTrees)
        }
        try Task.checkCancellation()

        try await tracks.upload()

        // Also count trees still waiting on an earlier stage (for example a planter whose
        // selfie hasn't uploaded yet), so the person knows to press upload again.
        let remaining = try remainingTreeCount()
        if remaining > 0 {
            throw UploadError.partialFailure(failedTrees: remaining)
        }
        if let captureError = captureError {
            throw captureError
        }
        Logger.log("UPLOAD V2: Finished")
    }
}

private extension V2UploadPipeline {

    func remainingTreeCount() throws -> Int {
        let fetchRequest: NSFetchRequest<TreeCapture> = TreeCapture.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "uploaded == NO")
        return try environment.viewContext.count(for: fetchRequest)
    }
}
