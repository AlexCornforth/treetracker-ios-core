//
//  TreeCaptureRequest.swift
//  Treetracker-Core
//

import Foundation

/// A tree capture in the v2 upload pack (`captures[]`).
///
/// Mirrors Android's `TreeCaptureRequest`. Every key is always written; nil values are
/// encoded as JSON `null`, matching Android's `explicitNulls = true`.
struct TreeCaptureRequest: Encodable, Equatable, Sendable {
    let sessionId: String
    let treeId: String
    let latitude: Double
    let longitude: Double
    let note: String?
    let imageUrl: String
    let capturedAt: String
    /// Not captured on iOS. Android also always sends `null`.
    let absStepCount: Int64?
    /// Not captured on iOS. Android also always sends `null`.
    let deltaStepCount: Int64?
    /// Not captured on iOS. Android also always sends `null`.
    let rotationMatrix: String?
    /// Not captured on iOS. Android also always sends `null`.
    let extraAttributes: String?

    init(
        sessionId: String,
        treeId: String,
        latitude: Double,
        longitude: Double,
        note: String?,
        imageUrl: String,
        capturedAt: Date,
        absStepCount: Int64? = nil,
        deltaStepCount: Int64? = nil,
        rotationMatrix: String? = nil,
        extraAttributes: String? = nil
    ) {
        self.sessionId = sessionId
        self.treeId = treeId
        self.latitude = latitude
        self.longitude = longitude
        self.note = note
        self.imageUrl = imageUrl
        self.capturedAt = V2DateFormatter.string(from: capturedAt)
        self.absStepCount = absStepCount
        self.deltaStepCount = deltaStepCount
        self.rotationMatrix = rotationMatrix
        self.extraAttributes = extraAttributes
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case treeId = "id"
        case latitude = "lat"
        case longitude = "lon"
        case note
        case imageUrl = "image_url"
        case capturedAt = "captured_at"
        case absStepCount = "abs_step_count"
        case deltaStepCount = "delta_step_count"
        case rotationMatrix = "rotation_matrix"
        case extraAttributes = "extra_attributes"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(treeId, forKey: .treeId)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(note, forKey: .note)
        try container.encode(imageUrl, forKey: .imageUrl)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(absStepCount, forKey: .absStepCount)
        try container.encode(deltaStepCount, forKey: .deltaStepCount)
        try container.encode(rotationMatrix, forKey: .rotationMatrix)
        try container.encode(extraAttributes, forKey: .extraAttributes)
    }
}
