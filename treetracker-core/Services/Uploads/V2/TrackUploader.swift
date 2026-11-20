//
//  TrackUploader.swift
//  Treetracker-Core
//

import Foundation
import CoreData

/// Stage 5: uploads the `_tracks` bundle, then deletes the uploaded locations
/// (as v1 and Android do).
///
/// Only locations whose session is already uploaded are sent.
@MainActor
final class TrackUploader {

    private let environment: V2UploadEnvironment

    init(environment: V2UploadEnvironment) {
        self.environment = environment
    }

    func upload() async throws {
        let uploadedSessionIds = try uploadedSessionIdSet()

        let fetchRequest: NSFetchRequest<LocationDataEntity> = LocationDataEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(
            format: "uploaded == NO AND capturedAt != nil AND planterCheckInId IN %@",
            Array(uploadedSessionIds)
        )
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "capturedAt", ascending: true)]
        let locations = try environment.fetch(fetchRequest)

        if !locations.isEmpty {
            let grouped = Dictionary(grouping: locations) { $0.planterCheckInId ?? "" }
            let sessionIds = grouped.keys.sorted()

            for batch in sessionIds.chunked(intoBatchesOf: environment.configuration.batchSize) {
                try Task.checkCancellation()
                let batchLocations = batch.flatMap { grouped[$0] ?? [] }
                let requests = batch.map { sessionId in
                    TracksRequest(
                        sessionId: sessionId,
                        locations: (grouped[sessionId] ?? []).compactMap(Self.request(for:))
                    )
                }
                let bundle = V2UploadBundle.tracks(requests, deviceId: environment.deviceId)
                try await environment.send(
                    bundle,
                    for: batchLocations.map(\.objectID),
                    as: LocationDataEntity.self,
                    // LocationDataEntity has no bundle id attribute; v1 does not record one either.
                    recordBundleId: { _, _ in },
                    markUploaded: { $0.uploaded = true }
                )
            }
        } else {
            Logger.log("UPLOAD V2: No tracks to upload")
        }

        try clearUploadedLocations()
    }
}

private extension TrackUploader {

    static func request(for location: LocationDataEntity) -> TrackLocationRequest? {
        guard let capturedAt = location.capturedAt else {
            return nil
        }
        return TrackLocationRequest(
            accuracy: location.accuracy,
            capturedAt: capturedAt,
            latitude: location.latitude,
            longitude: location.longitude
        )
    }

    func uploadedSessionIdSet() throws -> Set<String> {
        let fetchRequest = NSFetchRequest<NSDictionary>(entityName: "PlanterIdentification")
        fetchRequest.predicate = NSPredicate(format: "sessionUploaded == YES AND uuid != nil")
        fetchRequest.resultType = .dictionaryResultType
        fetchRequest.propertiesToFetch = ["uuid"]
        return Set(try environment.viewContext.fetch(fetchRequest).compactMap { $0["uuid"] as? String })
    }

    func clearUploadedLocations() throws {
        let fetchRequest: NSFetchRequest<LocationDataEntity> = LocationDataEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "uploaded == YES")
        let locations = try environment.fetch(fetchRequest)
        guard !locations.isEmpty else {
            return
        }
        locations.forEach { environment.viewContext.delete($0) }
        try environment.save()
    }
}
