//
//  YNABEntities.swift
//  Hazel
//
//  AppEntity/EntityQuery types so Siri/Shortcuts can present a live picker
//  of the signed-in user's YNAB budgets, accounts, and categories. Account
//  and category options depend on which budget was picked, since the shared
//  YNAB account this app was built for has one budget per person.
//

import AppIntents

nonisolated struct YNABBudgetEntity: AppEntity {
    let id: String
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "YNAB Budget"
    static let defaultQuery = YNABBudgetQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

nonisolated struct YNABBudgetQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [YNABBudgetEntity] {
        try await allBudgets().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [YNABBudgetEntity] {
        try await allBudgets()
    }

    private func allBudgets() async throws -> [YNABBudgetEntity] {
        guard let token = YNABAuthService.currentAccessToken else {
            throw YNABIntentError.notAuthenticated
        }
        do {
            let budgets = try await YNABService.fetchBudgets(token: token)
            return budgets.map { YNABBudgetEntity(id: $0.id, name: $0.name) }
        } catch {
            throw YNABIntentError.from(error)
        }
    }
}

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
    @IntentParameterDependency<AddYNABTransactionIntent>(\.$budget)
    var transactionIntent

    func entities(for identifiers: [String]) async throws -> [YNABAccountEntity] {
        try await allAccounts().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [YNABAccountEntity] {
        try await allAccounts()
    }

    private func allAccounts() async throws -> [YNABAccountEntity] {
        guard let budgetID = transactionIntent?.budget.id else { return [] }
        guard let token = YNABAuthService.currentAccessToken else {
            throw YNABIntentError.notAuthenticated
        }
        do {
            let accounts = try await YNABService.fetchAccounts(budgetID: budgetID, token: token)
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
    @IntentParameterDependency<AddYNABTransactionIntent>(\.$budget)
    var transactionIntent

    func entities(for identifiers: [String]) async throws -> [YNABCategoryEntity] {
        try await allCategories().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [YNABCategoryEntity] {
        try await allCategories()
    }

    private func allCategories() async throws -> [YNABCategoryEntity] {
        guard let budgetID = transactionIntent?.budget.id else { return [] }
        guard let token = YNABAuthService.currentAccessToken else {
            throw YNABIntentError.notAuthenticated
        }
        do {
            let categories = try await YNABService.fetchCategories(budgetID: budgetID, token: token)
            return categories.map { YNABCategoryEntity(id: $0.id, name: $0.name) }
        } catch {
            throw YNABIntentError.from(error)
        }
    }
}
