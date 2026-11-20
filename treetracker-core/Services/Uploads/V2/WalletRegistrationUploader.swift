//
//  WalletRegistrationUploader.swift
//  Treetracker-Core
//

import Foundation
import CoreData

/// Stage 2: uploads check-in selfies, then the `_registrations` bundle (wallet registrations).
///
/// A planter's wallet registration needs the URL of their first check-in selfie, so the
/// selfies go first. Uploaded selfies are then deleted locally, except the current planter's,
/// which the profile screen shows (the same rule as v1).
@MainActor
final class WalletRegistrationUploader {

    private let environment: V2UploadEnvironment
    private let currentPlanterIdentifier: String?

    init(environment: V2UploadEnvironment, currentPlanterIdentifier: String?) {
        self.environment = environment
        self.currentPlanterIdentifier = currentPlanterIdentifier
    }

    func upload() async throws {
        try await uploadSelfies()
        try Task.checkCancellation()
        try await uploadRegistrations()
        deleteUploadedSelfies()
    }
}

private extension WalletRegistrationUploader {

    func uploadSelfies() async throws {
        let fetchRequest: NSFetchRequest<PlanterIdentification> = PlanterIdentification.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "photoURL == nil AND localPhotoPath != nil AND uuid != nil")
        let checkIns = try environment.fetch(fetchRequest)

        let ids = checkIns.map(\.objectID)
        let jobs: [ImageUploadJob] = checkIns.enumerated().compactMap { index, checkIn in
            guard let fileName = checkIn.localPhotoPath, let uuid = checkIn.uuid else {
                return nil
            }
            return ImageUploadJob(index: index, fileName: fileName, uuid: uuid, latitude: checkIn.latitude, longitude: checkIn.longitude)
        }

        guard !jobs.isEmpty else {
            return
        }

        var connectionError: Error?
        await environment.imageBatchUploader.upload(jobs) { outcome in
            switch outcome.result {
            case .success(let url):
                guard let checkIn = environment.existingObjects([ids[outcome.index]], as: PlanterIdentification.self).first else {
                    return
                }
                checkIn.photoURL = url
                do {
                    try environment.save()
                } catch {
                    Logger.log("UPLOAD V2: Could not save selfie URL: \(error)")
                }
            case .failure(let error):
                Logger.log("UPLOAD V2: Selfie upload failed: \(error)")
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

    func uploadRegistrations() async throws {
        let fetchRequest: NSFetchRequest<PlanterDetail> = PlanterDetail.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "walletRegistrationUploaded == NO")
        let planters = try environment.fetch(fetchRequest)

        // Planters whose first selfie has not uploaded yet wait for the next run.
        let ready: [(PlanterDetail, WalletRegistrationRequest)] = planters.compactMap { planter in
            guard let request = request(for: planter) else {
                return nil
            }
            return (planter, request)
        }

        guard !ready.isEmpty else {
            Logger.log("UPLOAD V2: No wallet registrations to upload")
            return
        }

        for batch in ready.chunked(intoBatchesOf: environment.configuration.batchSize) {
            try Task.checkCancellation()
            let bundle = V2UploadBundle.walletRegistrations(batch.map(\.1), deviceId: environment.deviceId)
            try await environment.send(
                bundle,
                for: batch.map(\.0.objectID),
                as: PlanterDetail.self,
                recordBundleId: { $0.walletRegistrationBundleId = $1 },
                markUploaded: { $0.walletRegistrationUploaded = true }
            )
        }
    }

    func request(for planter: PlanterDetail) -> WalletRegistrationRequest? {
        guard let uuid = planter.uuid,
              let wallet = planter.identifier,
              let firstName = planter.firstName,
              let lastName = planter.lastName,
              let photoURL = planter.firstIdentificationURL else {
            return nil
        }
        return WalletRegistrationRequest(
            registrationId: uuid,
            wallet: wallet,
            userPhotoUrl: photoURL,
            firstName: firstName,
            lastName: lastName,
            phone: planter.phoneNumber,
            email: planter.email,
            latitude: planter.latitude,
            longitude: planter.longitude,
            registeredAt: planter.createdAt ?? Date()
        )
    }

    /// Deletes local selfies that are safely on S3 and belong to a registered planter,
    /// keeping the current planter's selfies.
    func deleteUploadedSelfies() {
        let fetchRequest: NSFetchRequest<PlanterIdentification> = PlanterIdentification.fetchRequest()
        fetchRequest.predicate = NSPredicate(
            format: "localPhotoPath != nil AND photoURL != nil AND planter.walletRegistrationUploaded == YES"
        )
        guard let checkIns = try? environment.fetch(fetchRequest) else {
            return
        }
        checkIns
            .filter { $0.planter?.identifier != currentPlanterIdentifier }
            .forEach { checkIn in
                guard let fileName = checkIn.localPhotoPath else {
                    return
                }
                environment.removeLocalFile(named: fileName)
                checkIn.localPhotoPath = nil
            }
        do {
            try environment.save()
        } catch {
            Logger.log("UPLOAD V2: Could not save selfie deletions: \(error)")
        }
    }
}
