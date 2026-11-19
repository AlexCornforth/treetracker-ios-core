//
//  V2UploadSupport.swift
//  Treetracker-Core
//

import Foundation
import CoreData

// MARK: - Public types

/// How far a tree upload run has got. Reported after every capture bundle.
public struct UploadProgress: Equatable, Sendable {
    /// Trees uploaded so far in this run.
    public let uploadedTrees: Int
    /// Trees that were waiting to upload when the run started.
    public let totalTrees: Int

    public init(uploadedTrees: Int, totalTrees: Int) {
        self.uploadedTrees = uploadedTrees
        self.totalTrees = totalTrees
    }
}

/// Errors reported to `UploadManagerDelegate.uploadManager(_:didError:)` by the v2 uploader.
/// Progress is kept in every case, so pressing upload again carries on where this run stopped.
public enum UploadError: Error, LocalizedError {
    /// The device lost its internet connection. Nothing more can be uploaded until it is back.
    case notConnected(underlying: Error?)
    /// Several batches in a row uploaded nothing, so the run stopped instead of churning on.
    case repeatedBatchFailures(underlying: Error?)
    /// The run finished, but some trees could not be uploaded and are still waiting.
    case partialFailure(failedTrees: Int)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The internet connection was lost. Uploaded trees are saved. Press upload again to continue."
        case .repeatedBatchFailures:
            return "Uploads keep failing on this connection. Uploaded trees are saved. Press upload again to continue."
        case .partialFailure(let failedTrees):
            return "\(failedTrees) trees could not be uploaded. Press upload again to retry them."
        }
    }
}

// MARK: - Configuration

struct V2UploadConfiguration: Sendable {
    /// Trees per `_captures` bundle, and records per bundle for the other stages. Matches Android.
    var batchSize: Int = 50
    /// Photos uploaded at the same time. Kept low for slow, shared connections.
    var maxConcurrentImageUploads: Int = 4
    /// Stop the run after this many capture batches in a row upload nothing.
    var maxConsecutiveFailedBatches: Int = 3
    var retryPolicy: RetryPolicy = .default

    static let `default` = V2UploadConfiguration()
}

// MARK: - Retry

/// Retries an S3 call on transient network errors, with a cancellable backoff.
struct RetryPolicy: Sendable {

    /// The wait before each retry. Its count is the number of retries.
    let delays: [TimeInterval]

    static let `default` = RetryPolicy(delays: [1, 4])
    static let none = RetryPolicy(delays: [])

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw error
                }
                guard attempt < delays.count, NetworkErrorClassifier.isTransient(error) else {
                    throw error
                }
                let delay = delays[attempt]
                attempt += 1
                Logger.log("UPLOAD V2: Transient error, retry \(attempt) of \(delays.count) in \(delay)s: \(error)")
                if delay > 0 {
                    // Throws CancellationError if the upload is stopped while waiting.
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
    }
}

enum NetworkErrorClassifier {

    /// Errors worth retrying straight away: the connection is there but a request failed.
    static func isTransient(_ error: Error) -> Bool {
        urlErrorCodes(in: error).contains { code in
            [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost].contains(code)
        }
    }

    /// The device has no usable internet connection.
    static func isNotConnected(_ error: Error) -> Bool {
        urlErrorCodes(in: error).contains { code in
            [NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed].contains(code)
        }
    }

    /// URL error codes in the error and its underlying errors. The AWS SDK passes
    /// NSURLSession errors straight through, but may also wrap them.
    private static func urlErrorCodes(in error: Error) -> [Int] {
        var codes: [Int] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 5 {
            if nsError.domain == NSURLErrorDomain {
                codes.append(nsError.code)
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return codes
    }
}

// MARK: - Image files

/// Reads photos stored by `DocumentManager`. Called off the main actor.
protocol ImageDataReading: Sendable {
    func read(fileName: String) throws -> Data
}

/// Reads from the Documents directory, where `DocumentManager` stores tree photos and selfies.
struct DocumentsImageReader: ImageDataReading {
    func read(fileName: String) throws -> Data {
        let directory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return try Data(contentsOf: directory.appendingPathComponent(fileName))
    }
}

// MARK: - Bounded parallel image uploads

struct ImageUploadJob: Sendable {
    /// Identifies the job to the caller, which maps it back to its managed object on the main actor.
    let index: Int
    let fileName: String
    let uuid: String
    let latitude: Double
    let longitude: Double
}

struct ImageUploadOutcome: Sendable {
    let index: Int
    let result: Result<String, Error>
}

/// Uploads photos with at most `maxConcurrent` in flight.
///
/// One failed photo does not cancel the others. Each outcome is handed to `onEach` on the
/// main actor as soon as it arrives, so its URL can be saved straight away.
@MainActor
struct ImageBatchUploader {

    let reader: ImageDataReading
    let uploader: AsyncImageUploading
    let retryPolicy: RetryPolicy
    let maxConcurrent: Int

    func upload(_ jobs: [ImageUploadJob], onEach: (ImageUploadOutcome) -> Void) async {
        guard !jobs.isEmpty else {
            return
        }
        let reader = self.reader
        let uploader = self.uploader
        let retryPolicy = self.retryPolicy

        await withTaskGroup(of: ImageUploadOutcome.self) { group in
            var pending = jobs.makeIterator()

            for _ in 0..<max(1, maxConcurrent) {
                guard let job = pending.next() else {
                    break
                }
                _ = group.addTaskUnlessCancelled {
                    await Self.perform(job, reader: reader, uploader: uploader, retryPolicy: retryPolicy)
                }
            }

            for await outcome in group {
                onEach(outcome)
                if let job = pending.next() {
                    _ = group.addTaskUnlessCancelled {
                        await Self.perform(job, reader: reader, uploader: uploader, retryPolicy: retryPolicy)
                    }
                }
            }
        }
    }

    /// Runs off the main actor: reads the file and uploads it.
    nonisolated private static func perform(
        _ job: ImageUploadJob,
        reader: ImageDataReading,
        uploader: AsyncImageUploading,
        retryPolicy: RetryPolicy
    ) async -> ImageUploadOutcome {
        do {
            let data = try reader.read(fileName: job.fileName)
            let url = try await retryPolicy.run {
                try await uploader.uploadImage(
                    jpegData: data,
                    uuid: job.uuid,
                    latitude: job.latitude,
                    longitude: job.longitude
                )
            }
            return ImageUploadOutcome(index: job.index, result: .success(url))
        } catch {
            return ImageUploadOutcome(index: job.index, result: .failure(error))
        }
    }
}

// MARK: - Shared environment

/// Everything the v2 uploaders need. Core Data work happens here on the main actor,
/// because `viewContext` is a main-queue context.
@MainActor
struct V2UploadEnvironment {

    let coreDataManager: CoreDataManaging
    let documentManager: DocumentManaging
    let bundleUploader: V2BundleUploading
    let imageUploader: AsyncImageUploading
    let imageReader: ImageDataReading
    let deviceConfigurationService: DeviceConfigurationProviding
    let deviceInfoProvider: DeviceInfoProviding
    let configuration: V2UploadConfiguration

    var viewContext: NSManagedObjectContext {
        coreDataManager.viewContext
    }

    var deviceId: String {
        deviceInfoProvider.deviceId
    }

    var imageBatchUploader: ImageBatchUploader {
        ImageBatchUploader(
            reader: imageReader,
            uploader: imageUploader,
            retryPolicy: configuration.retryPolicy,
            maxConcurrent: configuration.maxConcurrentImageUploads
        )
    }

    /// Saves the view context, throwing instead of calling `fatalError` like `saveContext()`.
    func save() throws {
        if viewContext.hasChanges {
            try viewContext.save()
        }
    }

    func fetch<T: NSManagedObject>(_ request: NSFetchRequest<T>) throws -> [T] {
        try viewContext.fetch(request)
    }

    /// Looks objects up again by ID after an `await`, skipping any deleted in the meantime.
    func existingObjects<T: NSManagedObject>(_ ids: [NSManagedObjectID], as type: T.Type) -> [T] {
        ids.compactMap { id in
            guard let object = try? viewContext.existingObject(with: id) as? T, !object.isDeleted else {
                return nil
            }
            return object
        }
    }

    /// Uploads one bundle using Android's order: write the bundle id, put the file, then mark the records uploaded.
    ///
    /// - Parameters:
    ///   - ids: The records in the bundle.
    ///   - recordBundleId: Writes the bundle id onto a record before the upload.
    ///   - markUploaded: Marks a record uploaded after the upload succeeds.
    func send<T: NSManagedObject>(
        _ bundle: V2UploadBundle,
        for ids: [NSManagedObjectID],
        as type: T.Type,
        recordBundleId: (T, String) -> Void,
        markUploaded: (T) -> Void
    ) async throws {
        let encoded = try bundle.encoded()

        existingObjects(ids, as: type).forEach { recordBundleId($0, encoded.bundleId) }
        try save()

        let bundleUploader = self.bundleUploader
        _ = try await configuration.retryPolicy.run {
            try await bundleUploader.uploadBundle(json: encoded.json, bundleId: encoded.bundleId)
        }

        existingObjects(ids, as: type).forEach(markUploaded)
        try save()
        Logger.log("UPLOAD V2: Uploaded \(encoded.bundleId) (\(ids.count) records)")
    }

    /// Deletes a local photo file, tolerating a file that is already gone.
    func removeLocalFile(named fileName: String) {
        do {
            if try documentManager.fileExists(withFileName: fileName) {
                try documentManager.removeFile(withFileName: fileName)
            }
        } catch {
            Logger.log("UPLOAD V2: Could not delete local file \(fileName): \(error)")
        }
    }
}

extension Array {
    func chunked(intoBatchesOf size: Int) -> [[Element]] {
        let size = Swift.max(1, size)
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
