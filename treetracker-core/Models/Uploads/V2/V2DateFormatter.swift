//
//  V2DateFormatter.swift
//  Treetracker-Core
//

import Foundation

/// Date formatting used by the v2 upload pack.
///
/// Matches Android, which serialises `kotlinx.datetime.Instant` with `toString()`:
/// ISO-8601 in UTC with fractional seconds, e.g. `2024-03-01T10:15:30.123Z`.
enum V2DateFormatter {

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Timestamp prefix for S3 bundle keys, matching Android's `ObjectStorageClient.uploadBundle`
    /// (`yyyy-MM-dd-HH-mm-ss`, device local time).
    static func bundleKeyTimestamp(from date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter.string(from: date)
    }
}
