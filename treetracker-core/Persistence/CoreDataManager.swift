//
//  CoreDataManager.swift
//  TreeTracker
//
//  Created by Alex Cornforth on 30/06/2020.
//  Copyright © 2020 Greenstand. All rights reserved.
//

import CoreData

class CoreDataManager: CoreDataManaging {

    static let modelName = "TreeTracker"

    /// Loaded once and shared, so tests that create several managers don't get
    /// "Failed to find a unique match for an NSEntityDescription".
    static let model: NSManagedObjectModel = {
        let bundle = Bundle(for: CoreDataManager.self)
        guard let modelURL = bundle.url(forResource: modelName, withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
            fatalError("Unable to load managed object model \(modelName)")
        }
        return model
    }()

    private let storeDescription: NSPersistentStoreDescription?

    /// - Parameter storeDescription: The store to use. `nil` (the app) uses the default SQLite store;
    ///   tests pass an in-memory store.
    init(storeDescription: NSPersistentStoreDescription? = nil) {
        self.storeDescription = storeDescription
    }

    private lazy var persistentContainer: NSPersistentContainer = {
        return makePersistentContainer(
            name: Self.modelName,
            model: Self.model,
            storeDescription: storeDescription
        )
    }()

    var viewContext: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
}
