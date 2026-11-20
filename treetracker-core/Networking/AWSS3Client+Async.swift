//
//  AWSS3Client+Async.swift
//  Treetracker-Core
//

import Foundation
import AWSS3

// MARK: - Protocols used by the v2 upload pipeline

/// Uploads a v2 JSON bundle to the batch-uploads bucket and returns its URL.
protocol V2BundleUploading: Sendable {
    func uploadBundle(json: String, bundleId: String) async throws -> String
}

/// Uploads a JPEG to the images bucket and returns its public URL.
protocol AsyncImageUploading: Sendable {
    func uploadImage(jpegData: Data, uuid: String, latitude: Double, longitude: Double) async throws -> String
}

// MARK: - Registration flag

/// Records whether `AWSS3Client.registerS3CLient()` has run.
///
/// `AWSS3.s3(forKey:)` is imported as non-optional but returns nil before registration,
/// so the async uploader checks this flag first instead of crashing.
///
/// Safety invariant for `@unchecked Sendable`: the only mutable state is `registered`,
/// and it is only read or written while holding `lock`.
/// Removal plan: replace with `Mutex` when the minimum deployment target reaches iOS 18.
final class AWSS3Registration: @unchecked Sendable {

    static let shared = AWSS3Registration()

    private let lock = NSLock()
    private var registered = false

    static func markRegistered() {
        shared.lock.lock()
        shared.registered = true
        shared.lock.unlock()
    }

    static var isRegistered: Bool {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        return shared.registered
    }
}

// MARK: - AWS S3 implementation

enum AWSS3AsyncUploaderError: Error {
    case s3ClientNotRegistered
    case requestCreationFailed
    case jsonEncodingFailed
}

/// Async, cancellable S3 uploads for the v2 pipeline.
///
/// It only holds `Sendable` configuration values. The AWS client is looked up by key for
/// each call, using the same key that `AWSS3Client.registerS3CLient()` registers.
struct AWSS3AsyncUploader: V2BundleUploading, AsyncImageUploading {

    let imagesBucketName: String
    let batchUploadsBucketName: String
    let regionString: String
    let serviceKey: String

    init(configuration: AWSConfiguration, serviceKey: String = AWSS3Client.Constants.s3ServiceKey) {
        self.imagesBucketName = configuration.imagesBucketName
        self.batchUploadsBucketName = configuration.batchUploadsBucketName
        self.regionString = configuration.regionString
        self.serviceKey = serviceKey
    }

    func uploadImage(jpegData: Data, uuid: String, latitude: Double, longitude: Double) async throws -> String {
        // Same key format as v1 iOS and Android image uploads.
        let key = "\(Self.imageKeyTimestamp())_\(latitude)_\(longitude)_\(UUID().uuidString)_\(uuid).jpg"
        return try await put(data: jpegData, bucketName: imagesBucketName, key: key, acl: .publicRead)
    }

    func uploadBundle(json: String, bundleId: String) async throws -> String {
        guard let data = json.data(using: .utf8) else {
            throw AWSS3AsyncUploaderError.jsonEncodingFailed
        }
        // Android's key format: yyyy-MM-dd-HH-mm-ss_<UUID>_<bundleId>.json
        let key = "\(V2DateFormatter.bundleKeyTimestamp())_\(UUID().uuidString)_\(bundleId).json"
        // Bundles keep v1's private ACL: they contain planter names, phone numbers and emails.
        return try await put(data: data, bucketName: batchUploadsBucketName, key: key, acl: nil)
    }
}

private extension AWSS3AsyncUploader {

    static func imageKeyTimestamp(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy.MM.dd.HH.mm.ss"
        return formatter.string(from: date)
    }

    func put(data: Data, bucketName: String, key: String, acl: AWSS3ObjectCannedACL?) async throws -> String {
        try Task.checkCancellation()

        guard AWSS3Registration.isRegistered else {
            throw AWSS3AsyncUploaderError.s3ClientNotRegistered
        }
        guard let request = AWSS3PutObjectRequest() else {
            throw AWSS3AsyncUploaderError.requestCreationFailed
        }

        request.bucket = bucketName
        request.body = data
        request.key = key
        request.contentLength = NSNumber(value: data.count)
        if let acl = acl {
            request.acl = acl
        }

        let s3Client = AWSS3.s3(forKey: serviceKey)
        let cancellable = CancellableAWSRequest(request)
        let url = "https://\(bucketName).s3.\(regionString).amazonaws.com/\(key)"

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                // AWS calls the completion handler exactly once, including after `cancel()`.
                s3Client.putObject(request) { _, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: url)
                    }
                }
            }
        } onCancel: {
            cancellable.cancel()
        }
    }
}

/// Lets the cancellation handler cancel the in-flight AWS request.
///
/// Safety invariant for `@unchecked Sendable`: the wrapped request is configured before it
/// is wrapped and is not mutated afterwards. The only cross-thread call is `cancel()`, which
/// AWSRequest synchronises internally. Without it, a cancelled upload would keep waiting for
/// the network, because structured concurrency waits for child work to finish.
/// Removal plan: drop it if the AWS SDK ships async, Sendable APIs.
private final class CancellableAWSRequest: @unchecked Sendable {

    private let request: AWSRequest

    init(_ request: AWSRequest) {
        self.request = request
    }

    func cancel() {
        _ = request.cancel()
    }
}
