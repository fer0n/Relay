//
//  YNABEntities.swift
//  Relay
//
//  AppEntity/EntityQuery types so Siri/Shortcuts can present a live picker
//  of the signed-in user's YNAB accounts and categories, scoped to their
//  default plan (see YNABService.swift).
//

import AppIntents
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "YNABEntities")

nonisolated struct YNABAccountEntity: AppEntity {
    let id: String
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "YNAB Account"
    static let defaultQuery = YNABAccountQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

nonisolated struct YNABAccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [YNABAccountEntity] {
        await allAccounts().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [YNABAccountEntity] {
        await allAccounts()
    }

    /// Never throws: Shortcuts resolves this query just to render the
    /// account picker, so a throw here (expired token, API error) makes
    /// the picker fail to load rather than show an error. Missing/expired
    /// auth instead surfaces from `perform()` when the transaction is
    /// actually submitted.
    private func allAccounts() async -> [YNABAccountEntity] {
        guard let token = await YNABAuthService.validAccessToken() else {
            logger.error("YNABAccountQuery: no access token in Keychain")
            return []
        }
        do {
            let accounts = try await YNABAccountCacheStore.fetch(token: token)
            logger.log("YNABAccountQuery: fetched \(accounts.count, privacy: .public) accounts")
            return accounts.map { YNABAccountEntity(id: $0.id, name: $0.name) }
        } catch {
            // Also invalidates the stored token on a 401, so Relay's own
            // UI reflects "Not Connected" instead of silently failing.
            let mapped = YNABIntentError.from(error)
            logger.error("YNABAccountQuery: fetchAccounts failed: \(String(describing: mapped), privacy: .public)")
            return []
        }
    }
}

nonisolated struct YNABCategoryEntity: AppEntity {
    let id: String
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "YNAB Category"
    static let defaultQuery = YNABCategoryQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

nonisolated struct YNABCategoryQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [YNABCategoryEntity] {
        await allCategories().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [YNABCategoryEntity] {
        await allCategories()
    }

    /// Never throws — see YNABAccountQuery.allAccounts().
    private func allCategories() async -> [YNABCategoryEntity] {
        guard let token = await YNABAuthService.validAccessToken() else {
            logger.error("YNABCategoryQuery: no access token in Keychain")
            return []
        }
        do {
            let categories = try await YNABCategoryCacheStore.fetch(token: token)
            logger.log("YNABCategoryQuery: fetched \(categories.count, privacy: .public) categories")
            return YNABCategoryUsageStore.sorted(categories).map { YNABCategoryEntity(id: $0.id, name: $0.name) }
        } catch {
            let mapped = YNABIntentError.from(error)
            logger.error("YNABCategoryQuery: fetchCategories failed: \(String(describing: mapped), privacy: .public)")
            return []
        }
    }
}
