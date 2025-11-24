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
/// - Uses indirect observation to propogate changes to SwiftUI, by using keySignals (which is itself observationIgnored because we don't want changes to one key affecting other keys, so we use Observation on the KeySignal itself that it holds). This prevents internal modifications of dictionaryRepresentation (our main in-memory store) from triggering code in the Observation system before we're done, which can cause re-entrancy/deadlock issues.
///
/// Also note that we annotate TinyStorage as `nonisolated` as in Swift 6 MainActor is default for classes, which we do not want for TinyStorage, so we undo that (and make it not isolated) by using `nonisolated` so we can continue to handle all the threading/synchronization ourselves and allow TinyStorage to be called from any thread (except for the functions explicitly marked MainActor).
@Observable
nonisolated public final class TinyStorage: @unchecked Sendable {
    private let directoryURL: URL
    public let fileURL: URL
    
    /// Private in-memory store so each request doesn't have to go to disk.
    /// Note that as Data is stored (implementation oddity, using Codable you can't encode an abstract [String: any Codable] to Data) rather than the Codable object directly, it is decoded before being returned.
    @ObservationIgnored
    private var dictionaryRepresentation: [String: Data]
    
    @ObservationIgnored
    private var keySignals: [String: KeySignal] = [:]

    private enum GenerationState {
        case unknown
        case deleted
        
        /// The `generationID` of the file, which is weirdly exposed as an NSObject
        case known(id: NSObject)
    }

    /// Track the last known file generation identifier so we can ignore change notifications emitted for our own atomic writes.
    @ObservationIgnored
    private var generationState: GenerationState = .unknown
    
    /// Coordinates access to in-memory store
    private let dispatchQueue: DispatchQueue
    private let dispatchQueueKey = DispatchSpecificKey<Void>()
    
    private var source: DispatchSourceFileSystemObject?
    
    public static let didChangeNotification = Notification.Name(rawValue: "com.christianselig.TinyStorage.didChangeNotification")
    public static let changedKeysUserInfoKey = "TinyStorage.changedKeys"
    public static let writeIDUserInfoKey = "TinyStorage.WriteIDKey"
    
    private let logger: TinyStorageLogging
    
    /// True if this instance of TinyStorage is being created for use in an Xcode SwiftUI Preview, which as of Xcode 16 does not seem to like creating files (so we'll just store things in memory as a work around) nor does it like file watching/monitoring. See [#8](https://github.com/christianselig/TinyStorage/issues/8).
    private static let isBeingUsedInXcodePreview: Bool = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    
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
    public init(insideDirectory: URL, name: String, logger: TinyStorageLogging = OSLogTinyStorageLogger()) {
        let dispatchQueue = DispatchQueue(label: "TinyStorageInMemory", attributes: .concurrent)
        dispatchQueue.setSpecific(key: dispatchQueueKey, value: ())
        self.dispatchQueue = dispatchQueue
        
        let directoryURL = insideDirectory.appending(path: name, directoryHint: .isDirectory)
        self.directoryURL = directoryURL
        
        let fileURL = directoryURL.appending(path: "tiny-storage.plist", directoryHint: .notDirectory)
        self.fileURL = fileURL
        
        self.logger = logger
        
        self.dictionaryRepresentation = TinyStorage.retrieveStorageDictionary(directoryURL: directoryURL, fileURL: fileURL, logger: logger) ?? [:]

        do {
            let resourceValues = try fileURL.resourceValues(forKeys: [.generationIdentifierKey])
            
            if let generationIdentifier = resourceValues.generationIdentifier as? NSObject {
                generationState = .known(id: generationIdentifier)
            } else if !FileManager.default.fileExists(atPath: fileURL.path) {
                generationState = .deleted
            } else {
                generationState = .unknown
            }
        } catch {
            log(.error, "Failed to get resource values for \(fileURL.path()): \(error)")
            generationState = .unknown
        }

        log(.debug, "Initialized with file path: \(fileURL.path())")
        
        setUpFileWatch()
    }
    
    deinit {
        log(.info, "Deinitializing TinyStorage")
        source?.cancel()
    }
    
    // MARK: - Public API
    
    /// Retrieve a value from storage at the given key and decode it as the given type, throwing if there are  any errors in attemping to retrieve. Note that it will not throw if the key simply holds nothing currently, and instead will return nil. This function is a handy alternative to `retrieve` if you want more information about errors, for instance if you can recover from them or if you want to log errors to your own logger.
    ///
    /// - Parameters:
    ///   - type: The `Codable`-conforming type that the retrieved value should be decoded into.
    ///   - key: The key at which the value is stored.
    public func retrieveOrThrow<T: Codable>(type: T.Type, forKey key: any TinyStorageKey) throws -> T? {
        ensureNotAlreadyOnQueue()
           
        return try dispatchQueue.sync {
            guard let data = dictionaryRepresentation[key.rawValue] else {
                log(.info, "No key \(key.rawValue) found in storage")
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
    ///   - key: The key at which the value is stored.
    public func retrieve<T: Codable>(type: T.Type, forKey key: any TinyStorageKey) -> T? {
        do {
            return try retrieveOrThrow(type: type, forKey: key)
        } catch {
            log(.error, "Error retrieving JSON data for key: \(key.rawValue), for type: \(String(reflecting: type)), with error: \(error)")
            return nil
        }
    }
    
    /// Alternate version of `retrieve` that through the Observation framework will automatically update the UI upon the value for this particular key changing. Can also use the `@TinyStorageItem` property wrapper.
    @MainActor
    public func autoUpdatingRetrieve<T: Codable>(type: T.Type, forKey key: any TinyStorageKey) -> T? {
        _ = signal(for: key).value
        return retrieve(type: type, forKey: key)
    }
    
    /// Alternate version of `retrieveOrThrow` that through the Observation framework will automatically update the UI upon the value for this particular key changing. Can also use the `@TinyStorageItem` property wrapper.
    @MainActor
    public func autoUpdatingRetrieveOrThrow<T: Codable>(type: T.Type, forKey key: any TinyStorageKey) throws -> T? {
        _ = signal(for: key).value
        return try retrieveOrThrow(type: type, forKey: key)
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

    /// Returns true if a value exists for the given key without decoding it.
    ///
    /// Useful when you only need presence information (e.g., to decide between save vs. delete) without incurring decode cost.
    public func contains(_ key: any TinyStorageKey) -> Bool {
        dispatchQueue.sync {
            dictionaryRepresentation[key.rawValue] != nil
        }
    }

    /// Helper function that retrieves the object at the key and increments it before saving it back to storage and returns the newly incremented value. If no value is present at the key or there is a non `Int` value stored at the key (ensure the key was entered properly!), this function will assume you intended to initialize the value and thus write `incrementBy` to the key. If you pass a negative value to `incrementBy` it will be decremented by the absolute value of that amount.
    @discardableResult
    public func incrementInteger(forKey key: any TinyStorageKey, by incrementBy: Int = 1, writeID: String? = nil) -> Int {
        let keyString = key.rawValue
        var newValue: Int = 0
        var writeSucceeded = false

        dispatchQueue.sync(flags: .barrier) {
            guard !Self.isBeingUsedInXcodePreview else {
                let currentValue: Int = {
                    if let data = dictionaryRepresentation[keyString] {
                        return (try? JSONDecoder().decode(Int.self, from: data)) ?? 0
                    } else {
                        return 0
                    }
                }()

                newValue = currentValue + incrementBy

                if let encoded = try? JSONEncoder().encode(newValue) {
                    if dictionaryRepresentation[keyString] == encoded {
                        // Nothing changed
                        return
                    }
                    
                    dictionaryRepresentation[keyString] = encoded
                } else {
                    dictionaryRepresentation.removeValue(forKey: keyString)
                }

                writeSucceeded = true
                return
            }

            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?

            coordinator.coordinate(writingItemAt: fileURL, options: [.forReplacing], error: &coordinatorError) { url in
                // Pull the freshest data from disk
                let existingData: Data? = {
                    if FileManager.default.fileExists(atPath: url.path) {
                        do {
                            return try Data(contentsOf: url)
                        } catch {
                            log(.error, "Error reading existing increment data at \(url.path()): \(error)")
                            return nil
                        }
                    } else {
                        log(.info, "No existing storage file at \(url.path()); treating as empty before incrementing")
                        return nil
                    }
                }()

                let existingDictionary: [String: Data] = {
                    if let existingData {
                        do {
                            if let dictionary = try PropertyListSerialization.propertyList(from: existingData, format: nil) as? [String: Data] {
                                return dictionary
                            } else {
                                return [:]
                            }
                        } catch {
                            log(.error, "Error decoding property list from data: \(error)")
                            return [:]
                        }
                    } else {
                        return [:]
                    }
                }()
                
                var mergedDictionary = existingDictionary

                let currentValue: Int = {
                    if let data = existingDictionary[keyString] {
                        do {
                            return try JSONDecoder().decode(Int.self, from: data)
                        } catch {
                            log(.error, "Error decoding data as Int: \(error)")
                            return 0
                        }
                    } else {
                        return 0
                    }
                }()

                let updatedValue = currentValue + incrementBy
                let encoded: Data
                
                do {
                    encoded = try JSONEncoder().encode(updatedValue)
                } catch {
                    log(.error, "Failed to encode incremented value for key: \(keyString) with error: \(error)")
                    return
                }
                
                // Skip when value didn't actually change
                if mergedDictionary[keyString] == encoded {
                    return
                }

                mergedDictionary[keyString] = encoded

                let data: Data

                do {
                    data = try PropertyListSerialization.data(fromPropertyList: mergedDictionary, format: .binary, options: 0)
                } catch {
                    log(.error, "Error encoding dictionary to property list data: \(error)")
                    return
                }

                do {
                    try data.write(to: url, options: [.atomic, .noFileProtection])
                } catch {
                    log(.error, "Error writing incremented data for key \(keyString): \(error)")
                    return
                }

                dictionaryRepresentation = mergedDictionary

                do {
                    let resourceValues = try url.resourceValues(forKeys: [.generationIdentifierKey])

                    if let identifier = resourceValues.generationIdentifier as? NSObject {
                        generationState = .known(id: identifier)
                    } else {
                        generationState = .unknown
                    }
                } catch {
                    log(.error, "Error getting resource values for \(url.path()): \(error)")
                    generationState = .unknown
                }

                newValue = updatedValue
                writeSucceeded = true
            }

            if let coordinatorError {
                log(.error, "Error coordinating increment write: \(coordinatorError)")
            }
        }

        if writeSucceeded {
            Task(priority: .userInitiated) { @MainActor in
                notifyKeysChanged([keyString], writeID: writeID)
            }
        }

        return newValue
    }
    
    /// Stores a given value to disk (or removes if nil), throwing errors that occur while attempting to store. Note that thrown errors do not include errors thrown while writing the actual value to disk, only for the in-memory aspect.
    ///
    /// - Parameters:
    ///   - value: The `Codable`-conforming instance to store.
    ///   - key: The key that the value will be stored at.
    public func storeOrThrow(_ value: Codable?, forKey key: any TinyStorageKey, writeID: String? = nil) throws {
        let keyString = key.rawValue
        
        let valueData: Data?
        
        if let value {
            if let data = value as? Data {
                valueData = data
            } else {
                do {
                    valueData = try JSONEncoder().encode(value)
                } catch {
                    log(.error, "Failed to encode key: \(keyString) as data due to error: \(error)")
                    throw error
                }
            }
        } else {
            valueData = nil
        }
        
        var writeSucceeded = false
        
        // NSFileCoordinator brief overview: we use dispatchQueue to synchronize access for this process, and NSFileCoordinator to synchronize access *across* processes. Because of this, we wait until we get the go-ahead from NSFileCoordinator before doing anything, AND we read back the changes inside, in case anything changed from other processes in the time between asking for the lock and receiving it
        dispatchQueue.sync(flags: .barrier) {
            if Self.isBeingUsedInXcodePreview {
                // If the encoded bytes are identical, that means we're not changing the value so just return
                if dictionaryRepresentation[key.rawValue] == valueData {
                    return
                }
                
                dictionaryRepresentation[key.rawValue] = valueData
                writeSucceeded = true
                return
            }
            
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?
            
            coordinator.coordinate(writingItemAt: fileURL, options: [.forReplacing], error: &coordinatorError) { url in
                // Pull the freshest data from the disk, treating nothing as empty storage/initial state
                let existingData: Data? = {
                    if FileManager.default.fileExists(atPath: url.path) {
                        do {
                            return try Data(contentsOf: url)
                        } catch {
                            log(.error, "Error reading existing data at \(url.path()): \(error)")
                            return nil
                        }
                    } else {
                        log(.info, "No existing storage file at \(url.path()); treating as empty")
                        return nil
                    }
                }()
                
                let existingDictionary: [String: Data] = {
                    if let existingData {
                        do {
                            if let dictionary = try PropertyListSerialization.propertyList(from: existingData, format: nil) as? [String: Data] {
                                return dictionary
                            } else {
                                return [:]
                            }
                        } catch {
                            log(.error, "Error decoding property list from data: \(error)")
                            return [:]
                        }
                    } else {
                        return [:]
                    }
                }()
                
                var mergedDictionary = existingDictionary
                
                if let valueData {
                    mergedDictionary[keyString] = valueData
                } else {
                    mergedDictionary.removeValue(forKey: keyString)
                }
                
                // Skip disk write and notification if the encoded bytes are unchanged
                if existingDictionary[keyString] == valueData {
                    return
                }

                let data: Data
                
                do {
                    data = try PropertyListSerialization.data(fromPropertyList: mergedDictionary, format: .binary, options: 0)
                } catch {
                    log(.error, "Error encoding dictionary to property list data: \(error)")
                    return
                }
                
                do {
                    try data.write(to: url, options: [.atomic, .noFileProtection])
                } catch {
                    log(.error, "Error writing merged data for key \(keyString): \(error)")
                    return
                }
                
                dictionaryRepresentation = mergedDictionary
                
                do {
                    let resourceValues = try url.resourceValues(forKeys: [.generationIdentifierKey])
                    
                    if let identifier = resourceValues.generationIdentifier as? NSObject {
                        generationState = .known(id: identifier)
                    } else {
                        generationState = .unknown
                    }
                } catch {
                    log(.error, "Error getting resource values for \(url.path()): \(error)")
                    generationState = .unknown
                }
                
                writeSucceeded = true
            }
            
            if let coordinatorError {
                log(.error, "Error coordinating write: \(coordinatorError)")
            }
        }
        
        guard writeSucceeded else { return }
        
        Task(priority: .userInitiated) { @MainActor in
            notifyKeysChanged([keyString], writeID: writeID)
        }
    }
    
    /// Stores a given value to disk (or removes if nil). Unlike `storeOrThrow` this function is akin to `set` in `UserDefaults` in that any errors thrown are discarded. If you would like more insight into errors see `storeOrThrow`.
    ///
    /// - Parameters:
    ///   - value: The `Codable`-conforming instance to store.
    ///   - key: The key that the value will be stored at.
    public func store(_ value: Codable?, forKey key: any TinyStorageKey, writeID: String? = nil) {
        do {
            try storeOrThrow(value, forKey: key, writeID: writeID)
        } catch {
            log(.error, "Error storing key: \(key.rawValue), with error: \(error)")
        }
    }
    
    /// Removes the value for the given key
    public func remove(key: any TinyStorageKey, writeID: String? = nil) {
        store(nil, forKey: key, writeID: writeID)
    }
    
    /// Completely resets the storage, removing all values
    public func reset(writeID: String? = nil) {
        guard !Self.isBeingUsedInXcodePreview else { return }
        
        var keysToNotify: Set<String> = []
        var resetFailed = false
        
        dispatchQueue.sync(flags: .barrier) {
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?
            var deleteError: Error?
            
            coordinator.coordinate(writingItemAt: fileURL, options: [.forDeleting], error: &coordinatorError) { url in
                do {
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                } catch {
                    deleteError = error
                }
            }
            
            if let coordinatorError {
                log(.error, "Error coordinating storage file removal: \(coordinatorError)")
                resetFailed = true
                return
            } else if let deleteError {
                self.log(.error, "Error removing storage file: \(deleteError)")
                resetFailed = true
                return
            }
            
            keysToNotify = Set(dictionaryRepresentation.keys)
            dictionaryRepresentation.removeAll()
            generationState = .deleted
            log(.info, "Successfully reset")
        }
        
        let keysToNotifyCopy = keysToNotify
        
        if !resetFailed && !keysToNotifyCopy.isEmpty {
            Task(priority: .userInitiated) { @MainActor in
                notifyKeysChanged(keysToNotifyCopy, writeID: writeID)
            }
        }
    }
    
    /// Migrates specified keys from the specified instance of `UserDefaults` into this instance of `TinyStorage` and stores to disk. As `UserDefaults` stores boolean values as 0 or 1 behind the scenes (so it's impossible to know if `1` refers to `true` or the integer value `1`, and `Codable` does care), you will need to specify which keys store Bool and which store non-boolean values in order for the migration to occur. If the key's value is improperly matched or unable to be decoded the logger will print an error and the key will be skipped.
    ///
    /// - Parameters:
    ///   - userDefaults: The instance of `UserDefaults` to migrate.
    ///   - nonBoolKeys: Keys for items in `UserDefaults` that store non-Bool values (eg: Strings, Codable types, Ints, etc.)
    ///   - boolKeys: Keys for items in `UserDefaults` that store Bool values (ie: `true`/`false`). Arrays and Dictionaries of `Bool` also go here.
    ///   - overwriteTinyStorageIfConflict: If `true` and a key exists both in this `TinyStorage` instance and the passed `UserDefaults`, the `UserDefaults` value will overwrite `TinyStorage`'s.
    ///
    /// ## Notes
    ///
    /// 1. This function leaves the contents of `UserDefaults` intact, if you want `UserDefaults` erased you will need to do that yourself.
    /// 2. **It is up to you** to determine that `UserDefaults` is in a valid state prior to calling `migrate`, it is recommended you check both `UIApplication.isProtectedDataAvailable` is `true` and that a trusted key is present (with a value) in your `UserDefaults` instance.
    /// 3. You should store a flag (for instance in `TinyStorage`) that this migration is complete once finished so you don't call this function repeatedly.
    /// 4. This `migrate` function does not support nested collections due to Swift not having any `AnyCodable` type and the complication in supporting deeply nested types. That means `[String: Any]` is fine, provided `Any` is not another array or dictionary. The same applies to Arrays, `[String]` is okay but `[[String]]` is not. This includes arrays of dictionaries. This does not mean `TinyStorage` itself does not support nested collections (it does), however the migrator does not. You are still free to migrate these types manually as a result (in which case look at the `bulkStore` function).
    /// 5. As TinyStorage does not support mixed collection types, neither does this `migrate` function. For instance an array of `[Any]` that contains both a `String` and `Int` is invalid.
    /// 6. TinyStorage encodes all floating point values as `Double` and all integer values as `Int`, but this does not preclude you from retrieving floating points as `Float32`, or integers as `Int8` for instance provided they fit.
    /// 7. If a value that is intended to be a `Double` is encoded as an `Int` (for instance, it just happens to be `6.0` at time of migration and it thus stored as an `Int`), this is not of concern as you can still retrieve this as a `Double` after the fact.
    /// 8. This function could theoretically fetch all the keys in `UserDefaults`, but `UserDefaults` stores a lot of data that Apple/iOS put in there that doesn't necessarily pertain to your app/need to be stored in `TinyStorage`, so it's required that you pass a set of keys for the keys you want to migrate.
    /// 9. `UserDefaults` has functions `integer/double(forKey:)` and a corresponding `Bool` method that return `0` and `false` respectively if no key is present (as does TinyStorage) but as part of migration TinyStorage will not store 0/false, for the value if the key is not present, it will simply return skip the key, storing nothing for it.
    public func migrate(userDefaults: UserDefaults, nonBoolKeys: Set<String>, boolKeys: Set<String>, overwriteTinyStorageIfConflict: Bool, writeID: String? = nil) {
        guard !Self.isBeingUsedInXcodePreview else { return }
  
        var preparedItems: [String: Data] = [:]
        
        for key in boolKeys {
            if let object = userDefaults.object(forKey: key), let encoded = encodeBoolForMigration(boolKey: key, object: object) {
                preparedItems[key] = encoded
            }
        }
        
        for key in nonBoolKeys {
            if let object = userDefaults.object(forKey: key), let encoded = encodeNonBoolForMigration(nonBoolKey: key, object: object) {
                preparedItems[key] = encoded
            }
        }
        
        var keysToNotify: Set<String> = []
        
        dispatchQueue.sync(flags: .barrier) {
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?
            
            coordinator.coordinate(writingItemAt: fileURL, options: [.forReplacing], error: &coordinatorError) { url in
                let existingData: Data? = {
                    if FileManager.default.fileExists(atPath: url.path) {
                        do {
                            return try Data(contentsOf: url)
                        } catch {
                            log(.error, "Error reading existing migration data at \(url.path()): \(error)")
                            return nil
                        }
                    } else {
                        log(.info, "No existing storage file at \(url.path()); treating as empty before migration")
                        return nil
                    }
                }()
                
                let existingDictionary: [String: Data] = {
                    if let existingData {
                        do {
                            if let dictionary = try PropertyListSerialization.propertyList(from: existingData, format: nil) as? [String: Data] {
                                return dictionary
                            } else {
                                return [:]
                            }
                        } catch {
                            log(.error, "Error decoding property list from data: \(error)")
                            return [:]
                        }
                    } else {
                        return [:]
                    }
                }()

                var mergedDictionary = existingDictionary
                var localKeysToNotify: Set<String> = []

                for (key, value) in preparedItems {
                    guard !shouldSkipKeyDuringMigration(key: key, overwriteTinyStorageIfConflict: overwriteTinyStorageIfConflict, existingDictionary: existingDictionary) else { continue }

                    // Skip no-op writes where the encoded bytes are identical
                    if existingDictionary[key] == value {
                        continue
                    }

                    mergedDictionary[key] = value
                    localKeysToNotify.insert(key)
                }
                
                // If nothing actually changed, skip disk write/notification
                if localKeysToNotify.isEmpty {
                    return
                }
                                
                let data: Data
                
                do {
                    data = try PropertyListSerialization.data(fromPropertyList: mergedDictionary, format: .binary, options: 0)
                } catch {
                    log(.error, "Error encoding dictionary to property list data: \(error)")
                    return
                }
                
                do {
                    try data.write(to: url, options: [.atomic, .noFileProtection])
                } catch {
                    log(.error, "Error writing migrated data to disk: \(error)")
                    return
                }
                
                dictionaryRepresentation = mergedDictionary

                do {
                    let resourceValues = try url.resourceValues(forKeys: [.generationIdentifierKey])
                    
                    if let identifier = resourceValues.generationIdentifier as? NSObject {
                        generationState = .known(id: identifier)
                    } else {
                        generationState = .unknown
                    }
                } catch {
                    log(.error, "Error getting resource values for \(url.path()): \(error)")
                    generationState = .unknown
                }

                keysToNotify = localKeysToNotify
                log(.info, "Completed migration")
            }
            
            if let coordinatorError {
                log(.error, "Error coordinating storage migration: \(coordinatorError)")
            }
        }
        
        if !keysToNotify.isEmpty {
            Task(priority: .userInitiated) { @MainActor in
                notifyKeysChanged(keysToNotify, writeID: writeID)
            }
        }
    }
        
    /// Store multiple items at once, which will only result in one disk write, rather than a disk write for each individual storage as would happen if you called `store` on many individual items. Handy during a manual migration. Also supports removal by setting a key to `nil`.
    ///
    /// - Parameters:
    ///   - items: An array of items to store with a single disk write, Codable is optional so users can set keys to nil as an indication to remove them from storage.
    ///   - skipKeyIfAlreadyPresent: If `true` (default value is `false`) and the key is already present in the existing store, the new value will not be stored. This turns this function into something akin to `UserDefaults`' `registerDefaults` function, handy for setting up initial values, such as a guess at a user's preferred temperature unit (Celisus or Fahrenheit) based on device locale.
    ///
    /// - Note: From what I understand Codable is already inherently optional due to Optional being Codable so this just makes it more explicit to the compiler so we can unwrap it easier, in other words there's no way to make it so folks can't pass in non-optional Codables when used as an existential (see: https://mastodon.social/@christianselig/113279213464286112)
    public func bulkStore<U: TinyStorageKey>(items: [U: (any Codable)?], skipKeyIfAlreadyPresent: Bool = false, writeID: String? = nil) {
        var keysToNotify: Set<String> = []
        
        dispatchQueue.sync(flags: .barrier) {
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?
            
            coordinator.coordinate(writingItemAt: fileURL, error: &coordinatorError) { url in
                // Pull the freshest data from the disk, treating nothing as empty storage/initial state
                let existingData = try? Data(contentsOf: url)
                
                let existingDictionary: [String: Data] = {
                    if let existingData {
                        do {
                            if let dictionary = try PropertyListSerialization.propertyList(from: existingData, format: nil) as? [String: Data] {
                                return dictionary
                            } else {
                                return [:]
                            }
                        } catch {
                            log(.error, "Error decoding property list from data: \(error)")
                            return [:]
                        }
                    } else {
                        return [:]
                    }
                }()
                
                var mergedDictionary = existingDictionary
                
                // Store a set of keys that we'll use to notify changes for if everything finishes without issue, otherwise we'd be writing directly to keysToNotify when we're not sure if everything even fully completed
                var localKeysToNotify: Set<String> = []

                for (key, value) in items {
                    let rawKey = key.rawValue
                    
                    if skipKeyIfAlreadyPresent, mergedDictionary[rawKey] != nil { continue }
                    
                    if let value {
                        let encoded: Data
                        
                        if let data = value as? Data {
                            encoded = data
                        } else {
                            do {
                                encoded = try JSONEncoder().encode(value)
                            } catch {
                                log(.error, "Failed to encode key: \(rawKey) as data due to error: \(error)")
                                continue
                            }
                        }
                        
                        // Skip no-op writes where the encoded bytes are identical
                        if mergedDictionary[rawKey] == encoded {
                            continue
                        }
                        
                        mergedDictionary[rawKey] = encoded
                        localKeysToNotify.insert(rawKey)
                    } else {
                        // This is a delete, but only mark as changed if the key actually existed
                        if mergedDictionary.removeValue(forKey: rawKey) != nil {
                            localKeysToNotify.insert(rawKey)
                        }
                    }
                }

                // If nothing actually changed, exit early
                if localKeysToNotify.isEmpty {
                    return
                }

                let data: Data
                
                do {
                    data = try PropertyListSerialization.data(fromPropertyList: mergedDictionary, format: .binary, options: 0)
                } catch {
                    log(.error, "Error encoding dictionary to property list data: \(error)")
                    return
                }
                
                do {
                    try data.write(to: url, options: [.atomic, .noFileProtection])
                } catch {
                    log(.error, "Error writing data to disk: \(error)")
                    return
                }
                
                dictionaryRepresentation = mergedDictionary
                
                do {
                    let resourceValues = try url.resourceValues(forKeys: [.generationIdentifierKey])
                    
                    if let identifier = resourceValues.generationIdentifier as? NSObject {
                        generationState = .known(id: identifier)
                    } else {
                        generationState = .unknown
                    }
                } catch {
                    log(.error, "Error getting resource values for \(url.path()): \(error)")
                    generationState = .unknown
                }

                keysToNotify = localKeysToNotify
            }
            
            if let coordinatorError {
                log(.error, "Error coordinating bulk store write: \(coordinatorError)")
            }
        }
        
        let keysToNotifyCopy = keysToNotify
        
        if !keysToNotifyCopy.isEmpty {
            Task(priority: .userInitiated) { @MainActor in
                notifyKeysChanged(keysToNotifyCopy, writeID: writeID)
            }
        }
    }
    
    // MARK: - Internal API
        
    private func log(_ level: TinyStorageLogLevel, _ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
        Self.log(logger: logger, level: level, message: message, file: file, function: function, line: line)
    }
    
    private static func log(logger: TinyStorageLogging, level: TinyStorageLogLevel, message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
        logger.log(level, message, file: file, function: function, line: line)
        
        #if !TINYSTORAGE_TESTING
        if level.shouldPauseDuringDebug {
            assertionFailure(message)
        }
        #endif
    }
    
    @MainActor
    fileprivate func signal(for key: any TinyStorageKey) -> KeySignal {
        if let s = keySignals[key.rawValue] { return s }
        let s = KeySignal()
        keySignals[key.rawValue] = s
        return s
    }
        
    /// Diff two of our `dictionaryRepresentation` versions and receive back a set of keys that were changed
    private func diffDictionaries(old: [String: Data], new: [String: Data]) -> Set<String> {
        var changed: Set<String> = []
        
        // Removals and changes
        for (oldKey, oldValue) in old {
            // Check that it exists in the new dictionary too, otherwise it's been removed and should be considered a changed key
            guard let newValue = new[oldKey] else {
                changed.insert(oldKey)
                continue
            }
            
            // If the value changed that's also a changed key
            if newValue != oldValue {
                changed.insert(oldKey)
            }
        }
        
        // Additions
        for newKey in new.keys where old[newKey] == nil {
            changed.insert(newKey)
        }
        
        return changed
    }
    
    @MainActor
    private func notifyKeysChanged(_ keys: Set<String>, writeID: String? = nil) {
        guard !keys.isEmpty else { return }
        
        var changesOccurred = false
        
        for key in keys {
            changesOccurred = true
            signal(for: key).bump()
        }
        
        if changesOccurred {
            var userInfo: [AnyHashable: Any] = [Self.changedKeysUserInfoKey: Array(keys)]
            
            if let writeID {
                userInfo[Self.writeIDUserInfoKey] = writeID
            }
            
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: self,
                userInfo: userInfo
            )
        }
    }
        
    /// Check that we're not causing a reentrancy deadlock from entering the queue when we're already calling from the queue
    private func ensureNotAlreadyOnQueue() {
        if DispatchQueue.getSpecific(key: dispatchQueueKey) != nil {
            #if !TINYSTORAGE_TESTING
            assertionFailure("About to enter dispatch queue when already on the queue which would cause a deadlock")
            #endif
        }
    }
    
    private static func createEmptyStorageFile(directoryURL: URL, fileURL: URL, logger: TinyStorageLogging) -> Bool {
        // First, create the empty data
        let storageDictionaryData: Data
        
        do {
            let emptyStorage: [String: Data] = [:]
            storageDictionaryData = try PropertyListSerialization.data(fromPropertyList: emptyStorage, format: .binary, options: 0)
        } catch {
            log(logger: logger, level: .error, message: "Error turning storage dictionary into Data: \(error)")
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
                    logger.log(.info, "Directory had already been created so continuing", file: #fileID, function: #function, line: #line)
                    directoryCreatedSuccessfully = true
                } else {
                    logger.log(.error, "Error creating directory: \(error)", file: #fileID, function: #function, line: #line)
                    directoryCreatedSuccessfully = false
                }
            }
        }
        
        if let directoryCoordinatorError {
            logger.log(.error, "Unable to coordinate creation of directory: \(directoryCoordinatorError)", file: #fileID, function: #function, line: #line)
            return false
        }
        
        guard directoryCreatedSuccessfully else {
            logger.log(.error, "Returning due to directory creation failing", file: #fileID, function: #function, line: #line)
            return false
        }
        
        // Now create the file within that directory
        var fileCoordinatorError: NSError?
        var fileCreatedSuccessfully = false
        
        coordinator.coordinate(writingItemAt: fileURL, options: [.forReplacing], error: &fileCoordinatorError) { url in
            fileCreatedSuccessfully = FileManager.default.createFile(atPath: url.path(), contents: storageDictionaryData, attributes: [.protectionKey: FileProtectionType.none])
        }
        
        if let fileCoordinatorError {
            logger.log(.error, "Error coordinating file writing: \(fileCoordinatorError)", file: #fileID, function: #function, line: #line)
            return false
        }
        
        return fileCreatedSuccessfully
    }
    
    /// Retrieves from disk the internal storage dictionary that serves as the basis for the storage structure. Static function so it can be called by `init`.
    private static func retrieveStorageDictionary(directoryURL: URL, fileURL: URL, logger: TinyStorageLogging) -> [String: Data]? {
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
                    logger.log(.error, "Error fetching TinyStorage file data: \(error)", file: #fileID, function: #function, line: #line)
                    return
                }
            }
        }
        
        if let coordinatorError {
            logger.log(.error, "Error coordinating access to read file: \(coordinatorError)", file: #fileID, function: #function, line: #line)
            return nil
        } else if needToCreateFile {
            if Self.isBeingUsedInXcodePreview {
                // Don't create files when being used in an Xcode preview
                return [:]
            } else if createEmptyStorageFile(directoryURL: directoryURL, fileURL: fileURL, logger: logger) {
                logger.log(.info, "Successfully created empty TinyStorage file at \(fileURL)", file: #fileID, function: #function, line: #line)
                
                // We just created it, so it would be empty
                return [:]
            } else {
                logger.log(.error, "Tried and failed to create TinyStorage file at \(fileURL.absoluteString) after attempting to retrieve it", file: #fileID, function: #function, line: #line)
                return nil
            }
        }
        
        guard let storageDictionaryData else { return nil }
        
        let storageDictionary: [String: Data]
        
        do {
            guard let properlyTypedDictionary = try PropertyListSerialization.propertyList(from: storageDictionaryData, format: nil) as? [String: Data] else {
                logger.log(.error, "JSON data is not of type [String: Data]", file: #fileID, function: #function, line: #line)
                return nil
            }
            
            storageDictionary = properlyTypedDictionary
        } catch {
            logger.log(.error, "Error decoding storage dictionary from Data: \(error)", file: #fileID, function: #function, line: #line)
            return nil
        }

        return storageDictionary
    }
    
    /// Sets up the monitoring of the file on disk for any changes, so we can detect when other processes modify it
    private func setUpFileWatch() {
        // Xcode Previews also do not like file watching it seems
        guard !Self.isBeingUsedInXcodePreview else { return }
        
        // Watch the directory rather than the file, as atomic writing will delete the old file which makes tracking it difficult otherwise
        let fileSystemRepresentation = FileManager.default.fileSystemRepresentation(withPath: directoryURL.path())
        let fileDescriptor = open(fileSystemRepresentation, O_EVTONLY)
        
        guard fileDescriptor > 0 else {
            log(.error, "Failed to set up file watch due to invalid file descriptor")
            return
        }

        // Even though atomic deletes the file, DispatchSource still picks this up as a write change, rather than a delete
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: [.write], queue: .main)
        self.source = source
        
        source.setEventHandler { [weak self] in
            // DispatchSource still fires for our own atomic writes (often twice), but processFileChangeEvent compares the file's generation identifier so in-process updates are ignored
            self?.processFileChangeEvent()
        }
        
        source.setCancelHandler {
            close(fileDescriptor)
        }
        
        source.resume()
    }

    /// Responds to the file change event
    private func processFileChangeEvent() {
        log(.info, "Processing a files changed event")
        
        var keysToNotify: Set<String> = []
        
        dispatchQueue.sync(flags: .barrier) {
            let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
            var currentGenerationIdentifier: NSObject?

            if fileExists {
                do {
                    let resourceValues = try fileURL.resourceValues(forKeys: [.generationIdentifierKey])
                    
                    if let identifier = resourceValues.generationIdentifier as? NSObject {
                        currentGenerationIdentifier = identifier
                        
                        if case .known(let lastIdentifier) = generationState, lastIdentifier.isEqual(identifier) {
                            log(.info, "Identified file change as our own and therefore ignoring")
                            return
                        }
                    } else {
                    }
                } catch {
                    log(.error, "Error getting resource values for \(fileURL.path()): \(error)")
                }
            } else if case .deleted = generationState {
                return
            }

            let oldDictionaryRepresentation = dictionaryRepresentation
            let newDictionaryRepresentation = TinyStorage.retrieveStorageDictionary(directoryURL: directoryURL, fileURL: fileURL, logger: logger) ?? [:]

            if oldDictionaryRepresentation != newDictionaryRepresentation {
                keysToNotify = diffDictionaries(old: oldDictionaryRepresentation, new: newDictionaryRepresentation)
                self.dictionaryRepresentation = newDictionaryRepresentation
            }

            if fileExists {
                if let currentGenerationIdentifier {
                    generationState = .known(id: currentGenerationIdentifier)
                } else {
                    generationState = .unknown
                }
            } else {
                generationState = .deleted
            }
        }
        
        let keysToNotifyCopy = keysToNotify
        
        if !keysToNotifyCopy.isEmpty {
            Task(priority: .userInitiated) { @MainActor in
                notifyKeysChanged(keysToNotifyCopy)
            }
        }
    }
    
    /// Helper function to perform a preliminary check if a key should be skipped for migration
    private func shouldSkipKeyDuringMigration(key: String, overwriteTinyStorageIfConflict: Bool, existingDictionary: [String: Data]) -> Bool {
        if existingDictionary[key] != nil {
            if overwriteTinyStorageIfConflict {
                log(.info, "Preparing to overwrite existing key \(key) during migration due to UserDefaults having the same key")
                return false
            } else {
                log(.info, "Skipping key \(key) during migration due to UserDefaults having the same key and overwriting is disabled")
                return true
            }
        } else {
            return false
        }
    }
    
    private func encodeBoolForMigration(boolKey: String, object: Any) -> Data? {
        // How UserDefaults treats Bool: when using object(forKey) it will return the integer value, and thus any value other than 0 or 1 will fail to cast as Bool and return nil (2, 2.5, etc. would return nil). However if you call bool(forKey) in UserDefaults anything non-zero will return true, including 1, 0.5, 1.5, 2, -10, etc., and mismatched values such as a string will return false.
        // As a result we are using object(forKey:) for more granularity that to hopefully catch potential user error
        if let boolValue = object as? Bool {
            do {
                return try JSONEncoder().encode(boolValue)
            } catch {
                log(.error, "Error encoding Bool to Data so could not migrate \(boolKey): \(error)")
                return nil
            }
        } else if let boolArray = object as? [Bool] {
            do {
                return try JSONEncoder().encode(boolArray)
            } catch {
                log(.error, "Error encoding Bool-array to Data so could not migrate \(boolKey): \(error)")
                return nil
            }
        } else if let boolDictionary = object as? [String: Bool] {
            // Reminder that strings are the only type UserDefaults permits as dictionary keys
            do {
                return try JSONEncoder().encode(boolDictionary)
            } catch {
                log(.error, "Error encoding Bool-dictionary to Data so could not migrate \(boolKey): \(error)")
                return nil
            }
        } else if let _ = object as? [[Any]] {
            log(.error, "Designated object at key \(boolKey) as Bool but gave nested array and nested collections are not a supported migration type, please perform migration manually")
            return nil
        } else if let _ = object as? [String: Any] {
            log(.error, "Designated object at key \(boolKey) as Bool but gave nested dictionary and nested collections are not a supported migration type, please perform migration manually")
            return nil
        } else {
            log(.error, "Designated object at key \(boolKey) as Bool but is actually \(type(of: object)) therefore not migrating")
            return nil
        }
    }
    
    private func encodeNonBoolForMigration(nonBoolKey: String, object: Any) -> Data? {
        // UserDefaults objects must be a property list type per Apple documentation https://developer.apple.com/documentation/foundation/userdefaults#2926904
        if let integerObject = object as? Int {
            do {
                return try JSONEncoder().encode(integerObject)
            } catch {
                log(.error, "Error encoding Int to Data so could not migrate \(nonBoolKey): \(error)")
                return nil
            }
        } else if let doubleObject = object as? Double {
            do {
                return try JSONEncoder().encode(doubleObject)
            } catch {
                log(.error, "Error encoding Double to Data so could not migrate \(nonBoolKey): \(error)")
                return nil
            }
        } else if let stringObject = object as? String {
            do {
                return try JSONEncoder().encode(stringObject)
            } catch {
                log(.error, "Error encoding String to Data so could not migrate \(nonBoolKey): \(error)")
                return nil
            }
        } else if let dateObject = object as? Date  {
            do {
                return try JSONEncoder().encode(dateObject)
            } catch {
                log(.error, "Error encoding String to Data so could not migrate \(nonBoolKey): \(error)")
                return nil
            }
        } else if let arrayObject = object as? [Any] {
            // Note that mixed arrays are not permitted as there's not a native AnyCodable type in Swift
            if let integerArray = arrayObject as? [Int] {
                do {
                    return try JSONEncoder().encode(integerArray)
                } catch {
                    log(.error, "Error encoding Integer array to Data so could not migrate \(nonBoolKey): \(error)")
                    return nil
                }
            } else if let doubleArray = arrayObject as? [Double] {
                do {
                    return try JSONEncoder().encode(doubleArray)
                } catch {
                    log(.error, "Error encoding Double array to Data so could not migrate \(nonBoolKey): \(error)")
                    return nil
                }
            } else if let stringArray = arrayObject as? [String] {
                do {
                    return try JSONEncoder().encode(stringArray)
                } catch {
                    log(.error, "Error encoding String array to Data so could not migrate \(nonBoolKey): \(error)")
                    return nil
                }
            } else if let dateArray = arrayObject as? [Date] {
                do {
                    return try JSONEncoder().encode(dateArray)
                } catch {
                    log(.error, "Error encoding Date array to Data so could not migrate \(nonBoolKey): \(error)")
                    return nil
                }
            } else if let _ = arrayObject as? [[String: Any]] {
                log(.error, "Nested collection types (in this case: dictionary inside array) are not supported by the migrator so \(nonBoolKey) was not migrated, please perform migration manually")
                return nil
            } else if let _ = arrayObject as? [[Any]]  {
                log(.error, "Nested collection types (in this case: array inside array) are not supported by the migrator so \(nonBoolKey) was not migrated, please perform migration manually")
                return nil
            } else if let dataArray = arrayObject as? [Data] {
                do {
                    return try JSONEncoder().encode(dataArray)
                } catch {
                    log(.error, "Error encoding Data array to Data so could not migrate \(nonBoolKey): \(error)")
                    return nil
                }
            } else {
                log(.error, "Mixed array type not supported in TinyStorage so not migrating \(nonBoolKey)")
                return nil
            }
        } else if let dictionaryObject = object as? [String: Any] {
            // Note that string dictionaries are the only supported dictionary type in UserDefaults
            // Also note that mixed dictionary values are not permitted as there's not a native AnyCodable type in Swift
            if let integerDictionary = dictionaryObject as? [String: Int] {
                do {
                    return try JSONEncoder().encode(integerDictionary)
                } catch {
                    log(.error, "Error encoding Integer dictionary to Data so could not migrate \(nonBoolKey): \(error)")
                    return nil
                }
            } else if let doubleDictionary = dictionaryObject as? [String: Double] {
                do {
                    return try JSONEncoder().encode(doubleDictionary)
                } catch {
                    log(.error, "Error encoding Double dictionary to Data so could not migrate \(nonBoolKey): \(error)")
                    return nil
                }
            } else if let stringDictionary = dictionaryObject as? [String: String] {
                do {
                    return try JSONEncoder().encode(stringDictionary)
                } catch {
                    log(.error, "Error encoding String dictionary to Data so could not migrate \(nonBoolKey): \(error)")
                    return nil
                }
            } else if let dateDictionary = dictionaryObject as? [String: Date] {
                do {
                    return try JSONEncoder().encode(dateDictionary)
                } catch {
                    log(.error, "Error encoding Date dictionary to Data so could not migrate \(nonBoolKey): \(error)")
                    return nil
                }
            } else if let dataDictionary = dictionaryObject as? [String: Data] {
                do {
                    return try JSONEncoder().encode(dataDictionary)
                } catch {
                    log(.error, "Error encoding Data dictionary to Data so could not migrate \(nonBoolKey): \(error)")
                    return nil
                }
            } else if let _ = dictionaryObject as? [String: [String: Any]] {
                log(.error, "Nested collection types (in this case: dictionary inside dictionary) are not supported by the migrator so \(nonBoolKey) was not migrated, please perform migration manually")
                return nil
            } else if let _ = dictionaryObject as? [String: [Any]] {
                log(.error, "Nested collection types (in this case: array inside dictionary) are not supported by the migrator so \(nonBoolKey) was not migrated, please perform migration manually")
                return nil
            } else {
                log(.error, "Mixed dictionary type not supported in TinyStorage so not migrating \(nonBoolKey)")
                return nil
            }
        } else if let dataObject = object as? Data {
            return dataObject
        } else {
            log(.error, "Unknown type found in UserDefaults: \(type(of: object))")
            return nil
        }
    }
}

nonisolated public protocol TinyStorageKey: Hashable, Sendable {
    var rawValue: String { get }
}

extension String: TinyStorageKey {
    public var rawValue: String { self }
}

@propertyWrapper
public struct TinyStorageItem<T: Codable>: DynamicProperty {
    private let storage: TinyStorage
    
    private let key: any TinyStorageKey
    private let defaultValue: T
    
    public init(wrappedValue: T, _ key: any TinyStorageKey, storage: TinyStorage) {
        self.defaultValue = wrappedValue
        self.storage = storage
        self.key = key
    }
    
    @MainActor
    public var wrappedValue: T {
        get { storage.autoUpdatingRetrieve(type: T.self, forKey: key) ?? defaultValue }
        nonmutating set { storage.store(newValue, forKey: key) }
    }
    
    @MainActor
    public var projectedValue: Binding<T> {
        Binding(
            get: { wrappedValue },
            set: { wrappedValue = $0 }
        )
    }
}

@MainActor
@Observable
private final class KeySignal {
    public private(set) var value: UInt = 0
    
    func bump() { value &+= 1 }
}

nonisolated public enum TinyStorageLogLevel {
    case debug, info, warning, error, fault, critical, trace, notice
    
    var shouldPauseDuringDebug: Bool {
        switch self {
        case .debug, .info, .warning, .trace, .notice: false
        case .error, .fault, .critical: true
        }
    }
}

nonisolated public protocol TinyStorageLogging {
    func log(_ level: TinyStorageLogLevel, _ message: String, file: String, function: String, line: Int)
}

nonisolated public struct OSLogTinyStorageLogger: TinyStorageLogging {
    private let logger: os.Logger = .init(subsystem: "com.christianselig.TinyStorage", category: "general")
    
    public init() {}
    
    public func log(_ level: TinyStorageLogLevel, _ message: String, file: String, function: String, line: Int) {
        let prefix = "[\(file)#\(line) \(function)] "
        
        switch level {
        case .debug: logger.debug("\(prefix)\(message)")
        case .notice: logger.notice("\(prefix)\(message)")
        case .trace: logger.trace("\(prefix)\(message)")
        case .critical: logger.critical("\(prefix)\(message)")
        case .info: logger.info("\(prefix)\(message)")
        case .warning: logger.warning("\(prefix)\(message)")
        case .error: logger.error("\(prefix)\(message)")
        case .fault: logger.fault("\(prefix)\(message)")
        }
    }
}
