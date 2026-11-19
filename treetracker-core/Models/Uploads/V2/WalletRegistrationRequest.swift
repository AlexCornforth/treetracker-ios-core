//
//  WalletRegistrationRequest.swift
//  Treetracker-Core
//

import Foundation

/// A planter registration in the v2 upload pack (`wallet_registrations[]`).
/// Mirrors Android's `WalletRegistrationRequest`.
struct WalletRegistrationRequest: Encodable, Equatable, Sendable {
    let registrationId: String
    let wallet: String
    let userPhotoUrl: String
    let firstName: String
    let lastName: String
    let phone: String?
    let email: String?
    let latitude: Double
    let longitude: Double
    let registeredAt: String

    init(
        registrationId: String,
        wallet: String,
        userPhotoUrl: String,
        firstName: String,
        lastName: String,
        phone: String?,
        email: String?,
        latitude: Double,
        longitude: Double,
        registeredAt: Date
    ) {
        self.registrationId = registrationId
        self.wallet = wallet
        self.userPhotoUrl = userPhotoUrl
        self.firstName = firstName
        self.lastName = lastName
        self.phone = phone
        self.email = email
        self.latitude = latitude
        self.longitude = longitude
        self.registeredAt = V2DateFormatter.string(from: registeredAt)
    }

    enum CodingKeys: String, CodingKey {
        case registrationId = "id"
        case wallet
        case userPhotoUrl = "user_photo_url"
        case firstName = "first_name"
        case lastName = "last_name"
        case phone
        case email
        case latitude = "lat"
        case longitude = "lon"
        case registeredAt = "registered_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(registrationId, forKey: .registrationId)
        try container.encode(wallet, forKey: .wallet)
        try container.encode(userPhotoUrl, forKey: .userPhotoUrl)
        try container.encode(firstName, forKey: .firstName)
        try container.encode(lastName, forKey: .lastName)
        try container.encode(phone, forKey: .phone)
        try container.encode(email, forKey: .email)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(registeredAt, forKey: .registeredAt)
    }
}
