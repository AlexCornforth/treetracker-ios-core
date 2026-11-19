//
//  Fakes.swift
//  Treetracker-CoreTests
//
//  In-memory stand-ins for S3, the file system and the device. Nothing here touches the
//  network: the v2 pipeline only reaches S3 through `V2BundleUploading` and
//  `AsyncImageUploading`, and these fakes record what would have been sent.
//

import Foundation
@testable import Treetracker_Core

// MARK: - S3 bundles

actor RecordingBundleUploader: V2BundleUploading {

    struct Upload: Sendable {
        let bundleId: String
        let json: String

        /// The suffix after the 32-character md5, e.g. `_captures`.
        var kind: String { String(bundleId.dropFirst(32)) }

        var object: [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        }
    }

    /// Return an error to fail an attempt. Called with the bundle id and the attempt number for that kind.
    typealias FailureRule = @Sendable (_ kind: String, _ attempt: Int) -> Error?

    private(set) var uploads: [Upload] = []
    private(set) var attemptedKinds: [String] = []
    private var attemptsByKind: [String: Int] = [:]
    private var failureRule: FailureRule?
    private var suspendKinds: Set<String> = []

    func failWhen(_ rule: @escaping FailureRule) {
        failureRule = rule
    }

    /// Bundles of this kind wait until the task is cancelled.
    func suspendUntilCancelled(kind: String) {
        suspendKinds.insert(kind)
    }

    func uploadBundle(json: String, bundleId: String) async throws -> String {
        let kind = String(bundleId.dropFirst(32))
        attemptedKinds.append(kind)
        attemptsByKind[kind, default: 0] += 1
        let attempt = attemptsByKind[kind] ?? 1

        if suspendKinds.contains(kind) {
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        }
        if let error = failureRule?(kind, attempt) {
            throw error
        }
        uploads.append(Upload(bundleId: bundleId, json: json))
        return "https://batch.example.invalid/\(bundleId).json"
    }

    func uploads(ofKind kind: String) -> [Upload] {
        uploads.filter { $0.kind == kind }
    }
}

// MARK: - S3 images

actor RecordingImageUploader: AsyncImageUploading {

    typealias FailureRule = @Sendable (_ uuid: String, _ attempt: Int) -> Error?

    private(set) var uploadedUUIDs: [String] = []
    private(set) var attemptsByUUID: [String: Int] = [:]
    private(set) var maxInFlight = 0
    private var inFlight = 0
    private var failureRule: FailureRule?

    func failWhen(_ rule: @escaping FailureRule) {
        failureRule = rule
    }

    func uploadImage(jpegData: Data, uuid: String, latitude: Double, longitude: Double) async throws -> String {
        attemptsByUUID[uuid, default: 0] += 1
        let attempt = attemptsByUUID[uuid] ?? 1

        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }

        // Suspend so that other uploads can overlap, as real network calls do.
        try await Task.sleep(nanoseconds: 1_000_000)

        if let error = failureRule?(uuid, attempt) {
            throw error
        }
        uploadedUUIDs.append(uuid)
        return "https://images.example.invalid/\(uuid).jpg"
    }
}

// MARK: - Files

struct FakeImageReader: ImageDataReading {
    var missingFiles: Set<String> = []

    func read(fileName: String) throws -> Data {
        if missingFiles.contains(fileName) {
            throw CocoaError(.fileNoSuchFile)
        }
        return Data("jpeg:\(fileName)".utf8)
    }
}

final class FakeDocumentManager: DocumentManaging {

    var existingFiles: Set<String> = []
    private(set) var removedFiles: [String] = []

    func store(data: Data, withFileName fileName: String) -> Result<String, Error> {
        existingFiles.insert(fileName)
        return .success(fileName)
    }

    func retrieveData(withFileName fileName: String) -> Result<Data, Error> {
        existingFiles.contains(fileName) ? .success(Data()) : .failure(CocoaError(.fileNoSuchFile))
    }

    func removeFile(withFileName fileName: String) throws {
        existingFiles.remove(fileName)
        removedFiles.append(fileName)
    }

    func fileExists(withFileName fileName: String) throws -> Bool {
        existingFiles.contains(fileName)
    }
}

// MARK: - Device

struct FakeDeviceInfoProvider: DeviceInfoProviding {
    var deviceId = "TEST-DEVICE-ID"
    var manufacturer = "Apple"
    var model = "iPhone"
    var systemVersion = "17.2"
    var machineName = "iPhone15,2"
}

struct FakeAppBundleInfoProvider: AppBundleInfoProviding {
    var versionNumber = "2.0"
    var buildNumber = "42"
    var sdkVersion = "17.2"
}

// MARK: - Manager

@MainActor
final class FakeKeepAlive: UploadKeepAlive {
    private(set) var beginCount = 0
    private(set) var endCount = 0

    func begin() { beginCount += 1 }
    func end() { endCount += 1 }
}

final class UploadDelegateSpy: UploadManagerDelegate {
    private(set) var started = 0
    private(set) var stopped = 0
    private(set) var errors: [Error] = []
    private(set) var progress: [UploadProgress] = []

    func uploadManagerDidStartUploadingTrees(_ uploadManager: UploadManaging) { started += 1 }
    func uploadManagerDidStopUploadingTrees(_ uploadManager: UploadManaging) { stopped += 1 }
    func uploadManager(_ uploadManager: UploadManaging, didError error: Error) { errors.append(error) }
    func uploadManager(_ uploadManager: UploadManaging, didUpdateProgress progress: UploadProgress) { self.progress.append(progress) }
}

// MARK: - Errors

enum TestNetworkError {
    static let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
    static let notConnected = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    static let forbidden = NSError(domain: "AWSS3ErrorDomain", code: 403)
}
