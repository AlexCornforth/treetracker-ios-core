//
//  SessionUploader.swift
//  Treetracker-Core
//

import Foundation
import CoreData

/// Stage 3: uploads the `_sessions` bundle. On iOS a session is a planter check-in.
///
/// A session is only sent when:
/// - its planter's wallet registration is already uploaded,
/// - its device configuration is already uploaded,
/// - it still has a tree or a location waiting to upload.
///
/// The last rule stops every historical check-in that v1 already covered from being sent again.
@MainActor
final class SessionUploader {

    private let environment: V2UploadEnvironment

    init(environment: V2UploadEnvironment) {
        self.environment = environment
    }

    func upload() async throws {
        let sessionIdsWithPendingLocations = try pendingLocationSessionIds()

        let fetchRequest: NSFetchRequest<PlanterIdentification> = PlanterIdentification.fetchRequest()
        fetchRequest.predicate = NSPredicate(
            format: """
            sessionUploaded == NO AND uuid != nil \
            AND planter.walletRegistrationUploaded == YES \
            AND deviceConfiguration.uploaded == YES \
            AND (SUBQUERY(trees, $tree, $tree.uploaded == NO).@count > 0 OR uuid IN %@)
            """,
            sessionIdsWithPendingLocations
        )
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        let checkIns = try environment.fetch(fetchRequest)

        let ready: [(PlanterIdentification, SessionRequest)] = checkIns.compactMap { checkIn in
            guard let request = request(for: checkIn) else {
                return nil
            }
            return (checkIn, request)
        }

        guard !ready.isEmpty else {
            Logger.log("UPLOAD V2: No sessions to upload")
            return
        }

        for batch in ready.chunked(intoBatchesOf: environment.configuration.batchSize) {
            try Task.checkCancellation()
            let bundle = V2UploadBundle.sessions(batch.map(\.1), deviceId: environment.deviceId)
            try await environment.send(
                bundle,
                for: batch.map(\.0.objectID),
                as: PlanterIdentification.self,
                recordBundleId: { $0.sessionBundleId = $1 },
                markUploaded: { $0.sessionUploaded = true }
            )
        }
    }
}

private extension SessionUploader {

    func request(for checkIn: PlanterIdentification) -> SessionRequest? {
        guard let sessionId = checkIn.uuid,
              let planter = checkIn.planter,
              let registrationId = planter.uuid,
              let wallet = planter.identifier,
              let deviceConfigurationId = checkIn.deviceConfiguration?.uuid else {
            return nil
        }
        return SessionRequest(
            sessionId: sessionId,
            originatingWalletRegistrationId: registrationId,
            targetWallet: wallet,
            organization: planter.organization ?? "",
            deviceConfigurationId: deviceConfigurationId
        )
    }

    func pendingLocationSessionIds() throws -> [String] {
        let fetchRequest = NSFetchRequest<NSDictionary>(entityName: "LocationDataEntity")
        fetchRequest.predicate = NSPredicate(format: "uploaded == NO AND planterCheckInId != nil")
        fetchRequest.resultType = .dictionaryResultType
        fetchRequest.propertiesToFetch = ["planterCheckInId"]
        fetchRequest.returnsDistinctResults = true
        return try environment.viewContext.fetch(fetchRequest).compactMap { $0["planterCheckInId"] as? String }
    }
}
