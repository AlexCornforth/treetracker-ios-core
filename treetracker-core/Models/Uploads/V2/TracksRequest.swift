//
//  TracksRequest.swift
//  Treetracker-Core
//

import Foundation

/// The locations recorded during one session, in the v2 upload pack (`tracks[]`).
///
/// Mirrors Android's `TracksRequest` / `LocationRequest`, which have no `@SerialName`
/// annotations, so their keys are camelCase.
struct TracksRequest: Encodable, Equatable, Sendable {
    let sessionId: String
    let locations: [TrackLocationRequest]
}

struct TrackLocationRequest: Encodable, Equatable, Sendable {
    let accuracy: Double
    let capturedAt: String
    let latitude: Double
    let longitude: Double

    init(accuracy: Double, capturedAt: Date, latitude: Double, longitude: Double) {
        self.accuracy = accuracy
        self.capturedAt = V2DateFormatter.string(from: capturedAt)
        self.latitude = latitude
        self.longitude = longitude
    }
}
