//
//  TinyStorage.swift
//  TinyStorage
//
//  Created by Christian Selig on 2024-10-06.
//

import Foundation
import SwiftUI
import OSLog

/// Similar to UserDefaults, but does not use disk encryption so files are more readily accessible.
///
/// Implementation details to consider:
///
/// - For more performant retrieval, data is also stored in memory
/// - Backed by NSFileCoordinator for disk access, so thread safe and inter-process safe, and backed by a serial dispatch queue for in-memory access
/// - Does NOT use NSFilePresenter due to me being scared. Uses DispatchSource to watch and respond to changes to the backing file.
/// - Internally data is stored as [String: Data] where Data is expected to be Codable (otherwise will error), this is to minimize needing to unmarshal the entire top-level dictionary into Codable objects for each key request/write. We store this [String: Data] object as a binary plist to disk as [String: Data] is not JSON encodable due to Data not being JSON
/// - Uses OSLog for logging
@Observable
public final class TinyStorage: @unchecked Sendable {
    private let directoryURL: URL
    public let fileURL: URL
    
    /// Private in-memory store so each request doesn't have to go to disk.
    /// Note that as Data is stored (implementation oddity, using Codable you can't encode an abstract [String: any Codable] to Data) rather than the Codable object directly, it is decoded before being returned.
    private var dictionaryRepresentation: [String: Data]
    
    /// Coordinates access to in-memory store
    private let dispatchQueue = DispatchQueue(label: "TinyStorageInMemory")
    
    private var source: DispatchSourceFileSystemObject?
    
    public static let didChangeNotification = Notification.Name(rawValue: "com.christianselig.TinyStorage.didChangeNotification")
    private let logger: Logger
    
    /// All keys currently present in storage
    public var allKeys: [any TinyStorageKey] {
        dispatchQueue.sync { return Array(dictionaryRepresentation.keys) }
    }
    
    /// Initialize an instance of `TinyStorage` for you to use.
    ///
    /// - Parameters:
    ///   - insideDirectory: The directory where the directory and backing plist file for this TinyStorage instance will live.
    ///   - name: The name of the directory that will be created to store the backing plist file.
    ///
    ///  - Note: TinyStorage creates a directory that the backing plist files lives in, for instance if you specify your name as "tinystorage-general-prefs" the file will live in ./tiny-storage-general-prefs/tiny-storage.plist where . is the directory you pass as `insideDirectory`.
    public init(insideDirectory: URL, name: String) {
        let directoryURL = insideDirectory.appending(path: name, directoryHint: .isDirectory)
        self.directoryURL = directoryURL
        
        let fileURL = directoryURL.appending(path: "tiny-storage.plist", directoryHint: .notDirectory)
        self.fileURL = fileURL
        
        let logger = Logger(subsystem: "com.christianselig.TinyStorage", category: "general")
        self.logger = logger
        
        self.dictionaryRepresentation = TinyStorage.retrieveStorageDictionary(directoryURL: directoryURL, fileURL: fileURL, logger: logger) ?? [:]

        logger.debug("Initialized with file path: \(fileURL.path())")
        
        setUpFileWatch()
    }
    
    deinit {
        logger.info("Deinitializing TinyStorage")
        source?.cancel()
    }
    
    // MARK: - Public API
    
    /// Retrieve a value from storage at the given key and decode it as the given type, throwing if there are  any errors in attemping to retrieve. Note that it will not throw if the key simply holds nothing currently, and instead will return nil. This function is a handy alternative to `retrieve` if you want more information about errors, for instance if you can recover from them or if you want to log errors to your own logger.
    ///
    /// - Parameters:
    ///   - type: The `Codable`-conforming type that the retrieved value should be decoded into.
    ///   - keys: The key at which the value is stored.
    public func retrieveOrThrow<T: Codable>(type: T.Type, forKey key: any TinyStorageKey) throws -> T? {
        return try dispatchQueue.sync {
            guard let data = dictionaryRepresentation[key.rawValue] else {
                logger.info("No key \(key.rawValue, privacy: .private) found in storage")
                return nil
            }
            
            if type == Data.self {
                // This should never fail, as Data is Codable and the the type is Data, but the compiler does not know that T is explicitly data (and I don't believe there's a way to mark this) so the cast is required
                return data as? T
            } else {
                return try JSONDecoder().decode(T.self, from: data)
            }
        }
    }
    
    /// Retrieve a value from storage at the given key and decode it as the given type, but unlike `retrieveOrThrow` this function acts like `UserDefaults` in that it discards errors and simply returns nil. See `retrieveOrThrow` if you would to have more insight into errors.
    ///
    /// - Parameters:
    ///   - type: The `Codable`-conforming type that the retrieved value should be decoded into.
    ///   - keys: The key at which the value is stored.
    public func retrieve<T: Codable>(type: T.Type, forKey key: any TinyStorageKey) -> T? {
        do {
            return try retrieveOrThrow(type: type, forKey: key)
        } catch {
            logger.error("Error retrieving JSON data for key: \(key.rawValue), for type: \(String(reflecting: type)), with error: \(error)")
            return nil
        }
    }
    
    /// Helper function that retrieves the object at the key and if it's a non-nil `Bool` will return its value, but if it's `nil`, will return `false`. Akin to `UserDefaults`' `bool(forKey:)` method.
    ///
    /// - Note: If there is a type mismatch (for instance the object stored at the key is a `Double`) will still return `false`, so you need to have confidence it was stored correctly.
    public func bool(forKey key: any TinyStorageKey) -> Bool {
        retrieve(type: Bool.self, forKey: key) ?? false
    }
    
    /// Helper function that retrieves the object at the key and if it's a non-nil `Int` will return its value, but if it's `nil`, will return `0`. Akin to `UserDefaults`' `integer(forKey:)` method.
    ///
    /// - Note: If there is a type mismatch (for instance the object stored at the key is a `String`) will still return `0`, so you need to have confidence it was stored correctly.
    public func integer(forKey key: any TinyStorageKey) -> Int {
        retrieve(type: Int.self, forKey: key) ?? 0
    }
    
    /// Helper function that retrieves the object at the key and increments it before saving it back to storage and returns the newly incremented value. If no value is present at the key or there is a non `Int` value stored at the key, this function will assume you intended to initialize the value and thus write `1` to the key.
    @discardableResult
    public func incrementInteger(forKey key: any TinyStorageKey, by incrementBy: Int = 1) -> Int {
        if var value = retrieve(type: Int.self, forKey: key) {
            value += incrementBy
            store(value, forKey: key)
            return value
        } else {
            store(1, forKey: key)
            return 1
        }
    }
    
    /// Stores a given value to disk (or removes if nil), throwing errors that occur while attempting to store. Note that thrown errors do not include errors thrown while writing the actual value to disk, only for the in-memory aspect.
    ///
    /// - Parameters:
    ///   - value: The `Codable`-conforming instance to store.
    ///   - key: The key that the value will be stored at.
    public func storeOrThrow(_ value: Codable?, forKey key: any TinyStorageKey) throws {
        if let value {
            // Encode the Codable object back to Data before storing in memory and on disk
            let valueData: Data
            
            if let data = value as? Data {
                // Given value is already of type Data, so use directly
                valueData = data
            } else {
                valueData = try JSONEncoder().encode(value)
            }
            
            dispatchQueue.sync {
                dictionaryRepresentation[key.rawValue] = valueData
                
                storeToDisk()
            }
        } else {
            dispatchQueue.sync {
                dictionaryRepresentation.removeValue(forKey: key.rawValue)
                storeToDisk()
            }
        }
        
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: nil)
    }
    
    /// Stores a given value to disk (or removes if nil). Unlike `storeOrThrow` this function is akin to `set` in `UserDefaults` in that any errors thrown are discarded. If you would like more insight into errors see `storeOrThrow`.
    ///
    /// - Parameters:
    ///   - value: The `Codable`-conforming instance to store.
    ///   - key: The key that the value will be stored at.
    public func store(_ value: Codable?, forKey key: any TinyStorageKey) {
        do {
            try storeOrThrow(value, forKey: key)
        } catch {
            logger.error("Error storing key: \(key.rawValue), with value: \(String(describing: value), privacy: .private), with error: \(error)")
        }
    }
    
    /// Removes the value for the given key
    public func remove(key: any TinyStorageKey) {
        store(nil, forKey: key)
    }
    
    /// Completely resets the storage, removing all values
    public func reset() {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var successfullyRemoved = false
        
        dispatchQueue.sync {
            coordinator.coordinate(writingItemAt: fileURL, options: [.forDeleting], error: &coordinatorError) { url in
                do {
                    try FileManager.default.removeItem(at: url)
                    successfullyRemoved = true
                } catch {
                    logger.error("Error removing storage file: \(error)")
                    successfullyRemoved = false
                }
            }
        }
        
        if let coordinatorError {
            logger.error("Error coordinating storage file removal: \(coordinatorError)")
            return
        } else if !successfullyRemoved {
            logger.error("Unable to remove storage file")
            return
        }
        
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: nil)
    }
    
    /// Migrates `UserDefaults` into this instance of `TinyStorage` and stores to disk.
    ///
    /// - Parameters:
    ///   - userDefaults: The instance of `UserDefaults` to migrate.
    ///   - keys: `UserDefaults` stores a lot of data that Apple/iOS put in there that doesn't necessarily pertain to your app/need to be stored in `TinyStorage`, so it's required that you pass a set of keys for the keys you want to migrate.
    ///   - overwriteTinyStorageIfConflict: If `true` and a key exists both in this `TinyStorage` instance and the passed `UserDefaults`, the `UserDefaults` value will overwrite `TinyStorage`'s.
    ///
    /// ## Notes
    ///
    /// 1. This function leaves the contents of `UserDefaults` intact, if you want `UserDefaults` erased you will need to do that yourself.
    /// 2. **It is up to you** to determine that `UserDefaults` is in a valid state prior to calling `migrate`, it is recommended you check both `UIApplication.isProtectedDataAvailable` is `true` and that a trusted key is present (with a value) in your `UserDefaults` instance.
    /// 3. You should store a flag (perhaps in `TinyStorage`!) that this migration is complete once finished so you don't call this function repeatedly
    /// 4. This `migrate` function does not support nested collections due to Swift not having any `AnyCodable` type and the complication in supporting deeply nested types. That means `[String: Any]` is fine, provided `Any` is not another array or dictionary. The same applies to Arrays, `[String]` is okay but `[[String]]` is not. This includes arrays of dictionaries. This does not mean `TinyStorage` itself does not support nested collections (it does), however the migrator does not. You are still free to migrate these types manually as a result (in which case look at the `bulkStore` function).
    /// 5. As TinyStorage does not support mixed collection types, neither does this `migrate` function. For instance an array of `[Any]` where `Any` could be a `String` or `Int` is invalid, as is `[String: Any]` where `Any` is not one consistent type.
    public func migrate(userDefaults: UserDefaults, keys: Set<String>, overwriteTinyStorageIfConflict: Bool) {
        dispatchQueue.sync {
            for key in keys {
                guard let object = userDefaults.object(forKey: key) else {
                    logger.warning("Requested migration of \(key) but it was not found in your UserDefaults instance")
                    continue
                }

                if dictionaryRepresentation[key] != nil {
                    if overwriteTinyStorageIfConflict {
                        logger.info("Preparing to overwrite existing key \(key) during migration due to UserDefaults having the same key")
                    } else {
                        logger.info("Skipping key \(key) during migration due to UserDefaults having the same key and overwriting is disabled")
                        continue
                    }
                }
                
                // UserDefaults objects must be a property list type per Apple documentation https://developer.apple.com/documentation/foundation/userdefaults#2926904
                if let integerObject = object as? Int {
                    do {
                        let data = try JSONEncoder().encode(integerObject)
                        dictionaryRepresentation[key] = data
                    } catch {
                        logger.error("Error encoding Int to Data so could not migrate \(key): \(error)")
                    }
                } else if let doubleObject = object as? Double {
                    do {
                        let data = try JSONEncoder().encode(doubleObject)
                        dictionaryRepresentation[key] = data
                    } catch {
                        logger.error("Error encoding Double to Data so could not migrate \(key): \(error)")
                    }
                } else if let stringObject = object as? String {
                    do {
                        let data = try JSONEncoder().encode(stringObject)
                        dictionaryRepresentation[key] = data
                    } catch {
                        logger.error("Error encoding String to Data so could not migrate \(key): \(error)")
                    }
                } else if let dateObject = object as? Date  {
                    do {
                        let data = try JSONEncoder().encode(dateObject)
                        dictionaryRepresentation[key] = data
                    } catch {
                        logger.error("Error encoding String to Data so could not migrate \(key): \(error)")
                    }
                } else if let arrayObject = object as? [Any] {
                    // Note that mixed arrays are not permitted as there's not a native AnyCodable type in Swift
                    if let integerArray = arrayObject as? [Int] {
                        do {
                            let data = try JSONEncoder().encode(integerArray)
                            dictionaryRepresentation[key] = data
                        } catch {
                            logger.error("Error encoding Integer array to Data so could not migrate \(key): \(error)")
                        }
                    } else if let doubleArray = arrayObject as? [Double] {
                        do {
                            let data = try JSONEncoder().encode(doubleArray)
                            dictionaryRepresentation[key] = data
                        } catch {
                            logger.error("Error encoding Double array to Data so could not migrate \(key): \(error)")
                        }
                    } else if let stringArray = arrayObject as? [String] {
                        do {
                            let data = try JSONEncoder().encode(stringArray)
                            dictionaryRepresentation[key] = data
                        } catch {
                            logger.error("Error encoding String array to Data so could not migrate \(key): \(error)")
                        }
                    } else if let dateArray = arrayObject as? [Date] {
                        do {
                            let data = try JSONEncoder().encode(dateArray)
                            dictionaryRepresentation[key] = data
                        } catch {
                            logger.error("Error encoding Date array to Data so could not migrate \(key): \(error)")
                        }
                    } else if let _ = arrayObject as? [[String: Any]] {
                        logger.warning("Nested collection types (in this case: dictionary inside array) are not supported by the migrator so \(key) was not migrated, please perform migration manually")
                    } else if let _ = arrayObject as? [[Any]]  {
                        logger.warning("Nested collection types (in this case: array inside array) are not supported by the migrator so \(key) was not migrated, please perform migration manually")
                    } else if let dataArray = arrayObject as? [Data] {
                        do {
                            let data = try JSONEncoder().encode(dataArray)
                            dictionaryRepresentation[key] = data
                        } catch {
                            logger.error("Error encoding Data array to Data so could not migrate \(key): \(error)")
                        }
                    } else {
                        logger.warning("Mixed array type not supported in TinyStorage so not migrating \(key)")
                    }
                } else if let dictionaryObject = object as? [String: Any] {
                    // Note that string dictionaries are the only supported dictionary type in UserDefaults
                    // Also note that mixed dictionary values are not permitted as there's not a native AnyCodable type in Swift
                    if let integerDictionary = dictionaryObject as? [String: Int] {
                        do {
                            let data = try JSONEncoder().encode(integerDictionary)
                            dictionaryRepresentation[key] = data
                        } catch {
                            logger.error("Error encoding Integer dictionary to Data so could not migrate \(key): \(error)")
                        }
                    } else if let doubleDictionary = dictionaryObject as? [String: Double] {
                        do {
                            let data = try JSONEncoder().encode(doubleDictionary)
                            dictionaryRepresentation[key] = data
                        } catch {
                            logger.error("Error encoding Double dictionary to Data so could not migrate \(key): \(error)")
                        }
                    } else if let stringDictionary = dictionaryObject as? [String: String] {
                        do {
                            let data = try JSONEncoder().encode(stringDictionary)
                            dictionaryRepresentation[key] = data
                        } catch {
                            logger.error("Error encoding String dictionary to Data so could not migrate \(key): \(error)")
                        }
                    } else if let dateDictionary = dictionaryObject as? [String: Date] {
                        do {
                            let data = try JSONEncoder().encode(dateDictionary)
                            dictionaryRepresentation[key] = data
                        } catch {
                            logger.error("Error encoding Date dictionary to Data so could not migrate \(key): \(error)")
                        }
                    } else if let dataDictionary = dictionaryObject as? [String: Data] {
                        do {
                            let data = try JSONEncoder().encode(dataDictionary)
                            dictionaryRepresentation[key] = data
                        } catch {
                            logger.error("Error encoding Data dictionary to Data so could not migrate \(key): \(error)")
                        }
                    } else if let _ = dictionaryObject as? [String: [String: Any]] {
                        logger.warning("Nested collection types (in this case: dictionary inside dictionary) are not supported by the migrator so \(key) was not migrated, please perform migration manually")
                    } else if let _ = dictionaryObject as? [String: [Any]] {
                        logger.warning("Nested collection types (in this case: array inside dictionary) are not supported by the migrator so \(key) was not migrated, please perform migration manually")
                    } else {
                        logger.warning("Mixed dictionary type not supported in TinyStorage so not migrating \(key)")
                    }
                } else if let dataObject = object as? Data {
                    dictionaryRepresentation[key] = dataObject
                } else {
                    logger.error("Unknown type found in UserDefaults: \(type(of: object))")
                }
            }
            
            storeToDisk()
        }
        
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: nil)
    }
    
    /// Store multiple items at once, which will only result in one disk write, rather than a disk write for each individual storage as would happen if you called `store` on many individual items. Handy during a manual migration. Also supports removal by setting a key to `nil`.
    ///
    /// - Parameters:
    ///   - items: An array of items to store with a single disk write, Codable is optional so users can set keys to nil as an indication to remove them from storage.
    ///   - skipKeyIfAlreadyPresent: If `true` and the key is already present in the existing store, the new value will not be stored. This turns this function into something akin to `UserDefaults`' `registerDefaults` function, handy for setting up initial values, such as a guess at a user's preferred temperature unit (Celisus or Fahrenheit) based on device locale.
    ///
    /// - Note: From what I understand Codable is already inherently optional due to Optional being Codable so this just makes it more explicit to the compiler so we can unwrap it easier, in other words there's no way to make it so folks can't pass in non-optional Codables when used as an existential (see: https://mastodon.social/@christianselig/113279213464286112)
    public func bulkStore<U: TinyStorageKey>(items: [U: (any Codable)?], skipKeyIfAlreadyPresent: Bool) {
        dispatchQueue.sync {
            for item in items {
                if skipKeyIfAlreadyPresent && dictionaryRepresentation[item.key.rawValue] != nil { continue }
                
                let valueData: Data
                
                if let itemValue = item.value {
                    if let data = item.value as? Data {
                        // Given value is already of type Data, so use directly
                        valueData = data
                    } else {
                        do {
                            valueData = try JSONEncoder().encode(itemValue)
                        } catch {
                            logger.error("Error bulk encoding new value for migration: \(String(describing: itemValue), privacy: .private), with error: \(error)")
                            continue
                        }
                    }
                } else {
                    // Nil value, indicating desire to remove
                    dictionaryRepresentation.removeValue(forKey: item.key.rawValue)
                    continue
                }

                dictionaryRepresentation[item.key.rawValue] = valueData
            }
            
            storeToDisk()
        }
        
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: nil)
    }
    
    // MARK: - Internal API
    
    private static func createEmptyStorageFile(directoryURL: URL, fileURL: URL, logger: Logger) -> Bool {
        // First, create the empty data
        let storageDictionaryData: Data
        
        do {
            let emptyStorage: [String: Data] = [:]
            storageDictionaryData = try PropertyListSerialization.data(fromPropertyList: emptyStorage, format: .binary, options: 0)
        } catch {
            logger.error("Error turning storage dictionary into Data: \(error)")
            return false
        }
        
        // Now create the directory that our file lives within. We create the file inside a directory as DispatchSource's file monitoring when used with atomic writing works better if monitoring a directory rather than a file directly
        // Important to not pass nil as the filePresenter: https://khanlou.com/2019/03/file-coordination/
        let coordinator = NSFileCoordinator()
        var directoryCoordinatorError: NSError?
        var directoryCreatedSuccessfully = false
        
        coordinator.coordinate(writingItemAt: directoryURL, options: [], error: &directoryCoordinatorError) { url in
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false, attributes: [.protectionKey: FileProtectionType.none])
                directoryCreatedSuccessfully = true
            } catch {
                let nsError = error as NSError
                
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteFileExistsError {
                    // Shouldn't happen, but just to be safe
                    logger.info("Directory had already been created so continuing")
                    directoryCreatedSuccessfully = true
                } else {
                    logger.error("Error creating directory: \(error)")
                    directoryCreatedSuccessfully = false
                }
            }
        }
        
        if let directoryCoordinatorError {
            logger.error("Unable to coordinate creation of directory: \(directoryCoordinatorError)")
            return false
        }
        
        guard directoryCreatedSuccessfully else {
            logger.error("Returning due to directory creation failing")
            return false
        }
        
        // Now create the file within that directory
        var fileCoordinatorError: NSError?
        var fileCreatedSuccessfully = false
        
        coordinator.coordinate(writingItemAt: fileURL, options: [.forReplacing], error: &fileCoordinatorError) { url in
            fileCreatedSuccessfully = FileManager.default.createFile(atPath: url.path(), contents: storageDictionaryData, attributes: [.protectionKey: FileProtectionType.none])
        }
        
        if let fileCoordinatorError {
            logger.error("Error coordinating file writing: \(fileCoordinatorError)")
            return false
        }
        
        return fileCreatedSuccessfully
    }

    /// Writes the in-memory store to disk.
    ///
    /// - Note: should only be called with a DispatchQueue lock on `dictionaryRepresentation``.
    private func storeToDisk() {
        let storageDictionaryData: Data
        
        do {
            storageDictionaryData = try PropertyListSerialization.data(fromPropertyList: dictionaryRepresentation, format: .binary, options: 0)
        } catch {
            logger.error("Error turning storage dictionary into Data: \(error)")
            return
        }
        
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        
        coordinator.coordinate(writingItemAt: fileURL, options: [.forReplacing], error: &coordinatorError) { url in
            do {
                try storageDictionaryData.write(to: url, options: [.atomic, .noFileProtection])
            } catch {
                logger.error("Error writing storage dictionary data: \(error)")
            }
        }
        
        if let coordinatorError {
            logger.error("Error coordinating writing to storage file: \(coordinatorError)")
        }
    }
    
    /// Retrieves from disk the internal storage dictionary that serves as the basis for the storage structure. Static function so it can be called by `init`.
    private static func retrieveStorageDictionary(directoryURL: URL, fileURL: URL, logger: Logger) -> [String: Data]? {
        let coordinator = NSFileCoordinator()
        var storageDictionaryData: Data?
        var coordinatorError: NSError?
        var needToCreateFile = false
        
        coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinatorError) { url in
            do {
                storageDictionaryData = try Data(contentsOf: url)
            } catch {
                let nsError = error as NSError
                
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                    needToCreateFile = true
                } else {
                    logger.error("Error fetching TinyStorage file data: \(error)")
                    return
                }
            }
        }
        
        if let coordinatorError {
            logger.error("Error coordinating access to read file: \(coordinatorError)")
            return nil
        } else if needToCreateFile {
            if createEmptyStorageFile(directoryURL: directoryURL, fileURL: fileURL, logger: logger) {
                logger.info("Successfully created empty TinyStorage file at \(fileURL)")
                
                // We just created it, so it would be empty
                return [:]
            } else {
                logger.error("Tried and failed to create TinyStorage file at \(fileURL.absoluteString) after attempting to retrieve it")
                return nil
            }
        }
        
        guard let storageDictionaryData else { return nil }
        
        let storageDictionary: [String: Data]
        
        do {
            guard let properlyTypedDictionary = try PropertyListSerialization.propertyList(from: storageDictionaryData, format: nil) as? [String: Data] else {
                logger.error("JSON data is not of type [String: Data]")
                return nil
            }
            
            storageDictionary = properlyTypedDictionary
        } catch {
            logger.error("Error decoding storage dictionary from Data: \(error)")
            return nil
        }

        return storageDictionary
    }
    
    /// Sets up the monitoring of the file on disk for any changes, so we can detect when other processes modify it
    private func setUpFileWatch() {
        // Watch the directory rather than the file, as atomic writing will delete the old file which makes tracking it difficult otherwise
        let fileSystemRepresentation = FileManager.default.fileSystemRepresentation(withPath: directoryURL.path())
        let fileDescriptor = open(fileSystemRepresentation, O_EVTONLY)
        
        guard fileDescriptor > 0 else {
            print("Failed to set up file watch due to invalid file descriptor")
            return
        }

        // Even though atomic deletes the file, DispatchSource still picks this up as a write change, rather than a delete
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: [.write], queue: .main)
        self.source = source
        
        source.setEventHandler { [weak self] in
            // Note that this will trigger even for changes we make within the same process (as these calls come in somewhat delayed versus when we change this with NSFileCoordinator), which will lead to this triggering and re-reading from disk again, which is wasteful, but I can't think of a way to get around this without poking holes in DispatchSource that would make it unreliable
            self?.processFileChangeEvent()
        }
        
        source.setCancelHandler {
            close(fileDescriptor)
        }
        
        source.resume()
    }

    /// Responds to the file change event
    private func processFileChangeEvent() {
        print("Processing a files changed event")
        var actualChangeOccurred = false
        
        dispatchQueue.sync {
            let newDictionaryRepresentation = TinyStorage.retrieveStorageDictionary(directoryURL: directoryURL, fileURL: fileURL, logger: logger) ?? [:]
            
            // Ensure something actually changed
            if self.dictionaryRepresentation != newDictionaryRepresentation {
                self.dictionaryRepresentation = newDictionaryRepresentation
                actualChangeOccurred = true
            }
        }
        
        if actualChangeOccurred {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: nil)
        }
    }
}

public protocol TinyStorageKey: Hashable, Sendable {
    var rawValue: String { get }
}

extension String: TinyStorageKey {
    public var rawValue: String { self }
}

@propertyWrapper
public struct TinyStorageItem<T: Codable & Sendable>: DynamicProperty, Sendable {
    @State private var storage: TinyStorage
    
    private let key: any TinyStorageKey
    private let defaultValue: T
    
    public init(wrappedValue: T, key: any TinyStorageKey, storage: TinyStorage) {
        self.defaultValue = wrappedValue
        self.storage = storage
        self.key = key
    }
    
    public var wrappedValue: T {
        get { storage.retrieve(type: T.self, forKey: key) ?? defaultValue }
        nonmutating set { storage.store(newValue, forKey: key) }
    }
    
    public var projectedValue: Binding<T> {
        Binding(
            get: { wrappedValue },
            set: { wrappedValue = $0 }
        )
    }
}
