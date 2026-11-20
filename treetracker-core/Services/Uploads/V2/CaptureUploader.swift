//
//  CaptureUploader.swift
//  Treetracker-Core
//

import Foundation
import CoreData

/// Stage 4: uploads tree photos and `_captures` bundles, 50 trees at a time.
///
/// Built for a large offline backlog uploaded over a slow, unreliable connection:
/// - Only object IDs are fetched up front; each batch of trees is loaded when it is needed.
/// - Up to 4 photos upload at once. Each URL is saved as soon as its photo uploads.
/// - One failed photo does not hold back the rest of its batch. That tree waits for the next run.
/// - A tree is marked uploaded only after its bundle reaches S3.
/// - If one batch fails, the next still runs. The run stops early when the device is offline,
///   or when several batches in a row upload nothing.
@MainActor
final class CaptureUploader {

    private let environment: V2UploadEnvironment
    private let onProgress: (UploadProgress) -> Void

    init(environment: V2UploadEnvironment, onProgress: @escaping (UploadProgress) -> Void) {
        self.environment = environment
        self.onProgress = onProgress
    }

    /// - Throws: `CancellationError` when stopped; `UploadError.notConnected` or
    ///   `.repeatedBatchFailures` when the run stops early; `UploadError.partialFailure`
    ///   at the end if some trees are still waiting.
    func upload() async throws {
        let ids = try pendingTreeIds()
        let total = ids.count
        guard total > 0 else {
            Logger.log("UPLOAD V2: No trees to upload")
            return
        }
        Logger.log("UPLOAD V2: \(total) trees to upload")

        var uploaded = 0
        var consecutiveFailedBatches = 0
        onProgress(UploadProgress(uploadedTrees: 0, totalTrees: total))

        for batch in ids.chunked(intoBatchesOf: environment.configuration.batchSize) {
            try Task.checkCancellation()

            do {
                let uploadedInBatch = try await uploadBatch(batch)
                uploaded += uploadedInBatch
                onProgress(UploadProgress(uploadedTrees: uploaded, totalTrees: total))

                if uploadedInBatch > 0 {
                    consecutiveFailedBatches = 0
                } else {
                    consecutiveFailedBatches += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as UploadError {
                throw error
            } catch {
                Logger.log("UPLOAD V2: Capture batch failed: \(error)")
                if NetworkErrorClassifier.isNotConnected(error) {
                    throw UploadError.notConnected(underlying: error)
                }
                consecutiveFailedBatches += 1
                if consecutiveFailedBatches >= environment.configuration.maxConsecutiveFailedBatches {
                    throw UploadError.repeatedBatchFailures(underlying: error)
                }
            }

            if consecutiveFailedBatches >= environment.configuration.maxConsecutiveFailedBatches {
                throw UploadError.repeatedBatchFailures(underlying: nil)
            }
        }

        let failed = total - uploaded
        if failed > 0 {
            throw UploadError.partialFailure(failedTrees: failed)
        }
    }
}

private extension CaptureUploader {

    /// Trees waiting to upload whose session the server already has, oldest first.
    func pendingTreeIds() throws -> [NSManagedObjectID] {
        let fetchRequest = NSFetchRequest<NSManagedObjectID>(entityName: "TreeCapture")
        fetchRequest.predicate = NSPredicate(format: "uploaded == NO AND planterIdentification.sessionUploaded == YES")
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        fetchRequest.resultType = .managedObjectIDResultType
        return try environment.viewContext.fetch(fetchRequest)
    }

    /// Uploads one batch. Returns how many of its trees were uploaded.
    func uploadBatch(_ ids: [NSManagedObjectID]) async throws -> Int {
        try await uploadMissingPhotos(for: ids)
        try Task.checkCancellation()

        let trees = environment.existingObjects(ids, as: TreeCapture.self)
        let ready: [(TreeCapture, TreeCaptureRequest)] = trees.compactMap { tree in
            guard let request = request(for: tree) else {
                return nil
            }
            return (tree, request)
        }

        defer {
            // Turn the batch back into faults so a long backlog doesn't build up in memory.
            environment.existingObjects(ids, as: TreeCapture.self)
                .filter { !$0.hasChanges }
                .forEach { environment.viewContext.refresh($0, mergeChanges: false) }
        }

        guard !ready.isEmpty else {
            Logger.log("UPLOAD V2: No trees in this batch have a photo URL yet")
            return 0
        }

        let readyIds = ready.map(\.0.objectID)
        let bundle = V2UploadBundle.captures(ready.map(\.1), deviceId: environment.deviceId)
        try await environment.send(
            bundle,
            for: readyIds,
            as: TreeCapture.self,
            recordBundleId: { $0.bundleId = $1 },
            markUploaded: { $0.uploaded = true }
        )

        deleteLocalPhotos(for: readyIds)
        return readyIds.count
    }

    func uploadMissingPhotos(for ids: [NSManagedObjectID]) async throws {
        let trees = environment.existingObjects(ids, as: TreeCapture.self).filter { $0.photoURL == nil }
        let treeIds = trees.map(\.objectID)

        let jobs: [ImageUploadJob] = trees.enumerated().compactMap { index, tree in
            guard let fileName = tree.localPhotoPath, let uuid = tree.uuid else {
                Logger.log("UPLOAD V2: Tree \(tree.uuid ?? "?") has no local photo and cannot upload")
                return nil
            }
            return ImageUploadJob(index: index, fileName: fileName, uuid: uuid, latitude: tree.latitude, longitude: tree.longitude)
        }

        var connectionError: Error?
        await environment.imageBatchUploader.upload(jobs) { outcome in
            switch outcome.result {
            case .success(let url):
                guard let tree = environment.existingObjects([treeIds[outcome.index]], as: TreeCapture.self).first else {
                    return
                }
                tree.photoURL = url
                do {
                    try environment.save()
                } catch {
                    Logger.log("UPLOAD V2: Could not save photo URL: \(error)")
                }
            case .failure(let error):
                Logger.log("UPLOAD V2: Photo upload failed: \(error)")
                if NetworkErrorClassifier.isNotConnected(error) {
                    connectionError = error
                }
            }
        }

        try Task.checkCancellation()
        if let connectionError = connectionError {
            throw UploadError.notConnected(underlying: connectionError)
        }
    }

    func request(for tree: TreeCapture) -> TreeCaptureRequest? {
        guard let treeId = tree.uuid,
              let imageUrl = tree.photoURL,
              let sessionId = tree.planterIdentification?.uuid,
              let createdAt = tree.createdAt else {
            return nil
        }
        return TreeCaptureRequest(
            sessionId: sessionId,
            treeId: treeId,
            latitude: tree.latitude,
            longitude: tree.longitude,
            note: tree.noteContent,
            imageUrl: imageUrl,
            capturedAt: createdAt
        )
    }

    func deleteLocalPhotos(for ids: [NSManagedObjectID]) {
        environment.existingObjects(ids, as: TreeCapture.self)
            .filter { $0.uploaded && $0.photoURL != nil }
            .forEach { tree in
                guard let fileName = tree.localPhotoPath else {
                    return
                }
                environment.removeLocalFile(named: fileName)
                tree.localPhotoPath = nil
            }
        do {
            try environment.save()
        } catch {
            Logger.log("UPLOAD V2: Could not save photo deletions: \(error)")
        }
    }
}
