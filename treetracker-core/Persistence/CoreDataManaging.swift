//
//  CoreDataManaging.swift
//  Treetracker-Core
//
//  Created by Alex Cornforth on 18/09/2023.
//

import CoreData

public protocol CoreDataManaging {
    var viewContext: NSManagedObjectContext { get }
    func saveContext()
    func perform<T: NSFetchRequestResult>(fetchRequest: NSFetchRequest<T>) -> [T]?
}

extension CoreDataManaging {

    func perform<T: NSFetchRequestResult>(fetchRequest: NSFetchRequest<T>) -> [T]? {
        do {
            let result = try viewContext.fetch(fetchRequest)
            return result
        } catch {
            return nil
        }
    }

    func saveContext() {
        let context = viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                let nserror = error as NSError
                fatalError("Unresolved error \(nserror), \(nserror.userInfo)")
            }
        }
    }

    func makePersistentContainer(modelName: String, bundle: Bundle) -> NSPersistentContainer {

        guard let modelURL = bundle.url(forResource: modelName, withExtension: "momd") else {
            fatalError("Unable to load managed object model URL")
        }

        guard let managedObjectModel = NSManagedObjectModel(contentsOf: modelURL) else {
            fatalError("Unable to load managed object model: \(modelURL)")
        }

        let container = NSPersistentContainer(name: modelName, managedObjectModel: managedObjectModel)
        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Unable to load persistent stores: \(error)")
            }
        }
        return container
    }

    /// Creates a container with lightweight migration switched on explicitly.
    ///
    /// The TreeTracker model has more than one version. Existing stores are migrated in place
    /// on first launch with an inferred mapping model, which requires every model change to be
    /// additive (new optional attributes, entities and relationships).
    func makePersistentContainer(
        name: String,
        model: NSManagedObjectModel,
        storeDescription: NSPersistentStoreDescription?
    ) -> NSPersistentContainer {
        let container = NSPersistentContainer(name: name, managedObjectModel: model)
        if let storeDescription = storeDescription {
            container.persistentStoreDescriptions = [storeDescription]
        }
        container.persistentStoreDescriptions.forEach { description in
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
        }
        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Unable to load persistent stores: \(error)")
            }
        }
        return container
    }
}
