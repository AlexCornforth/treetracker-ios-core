//
//  SupportTests.swift
//  Treetracker-CoreTests
//

import Foundation
import AWSCore
import Testing
@testable import Treetracker_Core

@Suite("Retry policy")
struct RetryPolicyTests {

    actor Counter {
        var value = 0
        func increment() -> Int {
            value += 1
            return value
        }
    }

    @Test func retriesTransientErrorsUpToTheLimit() async throws {
        let counter = Counter()
        await #expect(throws: (any Error).self) {
            _ = try await RetryPolicy(delays: [0, 0]).run { () async throws -> Int in
                _ = await counter.increment()
                throw TestNetworkError.timedOut
            }
        }
        #expect(await counter.value == 3)
    }

    @Test func doesNotRetryOtherErrors() async throws {
        let counter = Counter()
        await #expect(throws: (any Error).self) {
            _ = try await RetryPolicy(delays: [0, 0]).run { () async throws -> Int in
                _ = await counter.increment()
                throw TestNetworkError.forbidden
            }
        }
        #expect(await counter.value == 1)
    }

    @Test func classifiesWrappedNetworkErrors() {
        let wrapped = NSError(domain: "AWSS3ErrorDomain", code: 0, userInfo: [NSUnderlyingErrorKey: TestNetworkError.notConnected])
        #expect(NetworkErrorClassifier.isNotConnected(wrapped))
        #expect(!NetworkErrorClassifier.isTransient(wrapped))
        #expect(NetworkErrorClassifier.isTransient(TestNetworkError.timedOut))
    }
}

@Suite("Device configuration")
@MainActor
struct DeviceConfigurationServiceTests {

    @Test func createsANewRowOnlyWhenVersionsChange() throws {
        let store = TestStore()
        let first = DeviceConfigurationService(
            coreDataManager: store.coreDataManager,
            deviceInfoProvider: FakeDeviceInfoProvider(systemVersion: "17.2"),
            appBundleInfoProvider: FakeAppBundleInfoProvider(versionNumber: "2.0", buildNumber: "42")
        ).currentDeviceConfiguration()
        try store.save()

        let same = DeviceConfigurationService(
            coreDataManager: store.coreDataManager,
            deviceInfoProvider: FakeDeviceInfoProvider(systemVersion: "17.2"),
            appBundleInfoProvider: FakeAppBundleInfoProvider(versionNumber: "2.0", buildNumber: "42")
        ).currentDeviceConfiguration()
        #expect(same.objectID == first.objectID)

        let upgraded = DeviceConfigurationService(
            coreDataManager: store.coreDataManager,
            deviceInfoProvider: FakeDeviceInfoProvider(systemVersion: "18.0"),
            appBundleInfoProvider: FakeAppBundleInfoProvider(versionNumber: "2.0", buildNumber: "42"),
            now: { Date().addingTimeInterval(60) }
        ).currentDeviceConfiguration()
        #expect(upgraded.objectID != first.objectID)
        #expect(upgraded.sdkVersion == 18)
        #expect(upgraded.appBuild == 42)
    }
}

/// The tests must never reach S3.
@Suite("No network in tests")
struct NoNetworkTripwireTests {

    @Test func s3ClientIsNeverRegisteredInTests() {
        // Only `TreetrackerSDK.application(_:didFinishLaunchingWithOptions:)` registers it,
        // and no test creates the SDK.
        #expect(!AWSS3Registration.isRegistered)
        #expect(AWSServiceManager.default().defaultServiceConfiguration == nil)
    }

    @Test func realUploaderRefusesToRunWithoutARegisteredClient() async {
        let uploader = AWSS3AsyncUploader(configuration: AWSConfiguration(
            identityPoolId: "not-a-real-pool",
            regionType: .EUCentral1,
            regionString: "eu-central-1",
            imagesBucketName: "not-a-real-bucket",
            batchUploadsBucketName: "not-a-real-bucket"
        ))
        await #expect(throws: AWSS3AsyncUploaderError.self) {
            _ = try await uploader.uploadBundle(json: "{}", bundleId: "test")
        }
    }
}
