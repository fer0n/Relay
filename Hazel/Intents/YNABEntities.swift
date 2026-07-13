//
//  YNABEntities.swift
//  Hazel
//
//  AppEntity/EntityQuery types so Siri/Shortcuts can present a live picker
//  of the signed-in user's YNAB accounts and categories, scoped to their
//  default plan (see YNABService.swift).
//

import AppIntents

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
        try await allAccounts().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [YNABAccountEntity] {
        try await allAccounts()
    }

    private func allAccounts() async throws -> [YNABAccountEntity] {
        guard let token = YNABAuthService.currentAccessToken else {
            throw YNABIntentError.notAuthenticated
        }
        do {
            let accounts = try await YNABService.fetchAccounts(token: token)
            return accounts.map { YNABAccountEntity(id: $0.id, name: $0.name) }
        } catch {
            throw YNABIntentError.from(error)
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
        try await allCategories().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [YNABCategoryEntity] {
        try await allCategories()
    }

    private func allCategories() async throws -> [YNABCategoryEntity] {
        guard let token = YNABAuthService.currentAccessToken else {
            throw YNABIntentError.notAuthenticated
        }
        do {
            let categories = try await YNABService.fetchCategories(token: token)
            return categories.map { YNABCategoryEntity(id: $0.id, name: $0.name) }
        } catch {
            throw YNABIntentError.from(error)
        }
    }
}
