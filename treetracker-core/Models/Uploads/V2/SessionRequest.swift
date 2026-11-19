//
//  SessionRequest.swift
//  Treetracker-Core
//

import Foundation

/// A session in the v2 upload pack (`sessions[]`). On iOS a session is a planter check-in
/// (`PlanterIdentification`). Mirrors Android's `SessionRequest`.
struct SessionRequest: Encodable, Equatable, Sendable {
    let sessionId: String
    let originatingWalletRegistrationId: String
    let targetWallet: String
    let organization: String
    let deviceConfigurationId: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "id"
        case originatingWalletRegistrationId = "originating_wallet_registration_id"
        case targetWallet = "target_wallet"
        case organization
        case deviceConfigurationId = "device_configuration_id"
    }
}
