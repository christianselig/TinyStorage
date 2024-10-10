![Fancy logo](./banner-dark.png#gh-dark-mode-only)
![Fancy logo](./banner-light.png#gh-light-mode-only)

# TinyStorage 
<a href="https://www.emergetools.com/app/example/ios/examp_uQbTBp6Z4ryC/"><img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fwww.emergetools.com%2Fapi%2Fv2%2Fpublic_new_build%3FexampleId%3Dexamp_uQbTBp6Z4ryC%26platform%3Dios%26badgeOption%3Dversion_and_max_install_size&query=$.badgeMetadata&label=TinyStorage&logo=apple" /></a>

A simple, lightweight replacement for `UserDefaults` with more reliable access and native support for `Codable` types.

## Overview

Born out of [encountering issues with `UserDefaults`](https://christianselig.com/2024/10/beware-userdefaults/). As that blog post discusses, `UserDefaults` has more and more issues as of late with returning nil data when the device is locked and iOS "prelaunches" your app, leaving me honestly sort of unable to trust what `UserDefaults` returns. Combined with an API that doesn't really surface this information well, you can quite easily find yourself in a situation with difficult to track down bugs and data loss. This library seeks to address that fundamentally by not encrypting the backing file, allowing more reliable access to your saved data (if less secure, so don't store sensitive data), with some niceties sprinkled on top.

This means it's great for preferences and collections of data like bird species the user likes, but not for **sensitive** details. Do not store passwords/keys/tokens/secrets/diary entries/grammy's spaghetti recipe, anything that could be considered sensitive user information, as it's not encrypted on the disk. But don't use `UserDefaults` for sensitive details either as `UserDefaults` data is still fully decrypted when the device is locked so long as the user has unlocked the device once after reboot. Instead use `Keychain` for sensitive data.

As with `UserDefaults`, `TinyStorage` is intended to be used with values that are relatively small. Don't store massive databases in `TinyStorage` as it's not optimized for that, but it's plenty fast for retrieving stored `Codable` types. As a point of reference I'd say keep it under 1 MB.

This reliable storing of small, non-sensitive data (to me) is what `UserDefaults` was always intended to do well, so this library attempts to realize that vision. It's pretty simple and just a few hundred lines, far from a marvel of filesystem engineering, but just a nice little utility hopefully!

(Also to be clear, `TinyStorage` is not a wrapper for `UserDefaults`, it is a full replacement. It does not interface with the `UserDefaults` system in any way.)

## 🧪 Experimental/beta

TinyStorage is still in flux/active development, so APIs might change and there's a definite possibility of bugs. I mostly wanted to get it out early into the world in case anyone found it interesting, but consider forking it or pinning a specific version in Swift Package Manager if you don't want it changing a bunch. Feedback/PRs also more than welcome!

## Features

- Reliable access: even on first reboot or in application prewarming states, `TinyStorage` will read and write data properly
- Read and write Swift `Codable` types easily with the API
- Similar to `UserDefaults` uses an in-memory cache on top of the disk store to increase performance
- Thread-safe through an internal `DispatchQueue` so you can safely read/write across threads without having to coordinate that yourself
- Supports storing backing file in shared app container
- Uses `NSFileCoordinator` for coordinating reading/writing to disk so can be used safely across multiple processes at the same time (main target and widget target, for instance)
- When using across multiple processes, will automatically detect changes to file on disk and update accordingly
- SwiftUI property wrapper for easy use in a SwiftUI hierarchy (Similar to `@AppStorage`)
- Can subscribe to to `TinyStorage.didChangeNotification` in `NotificationCenter`, and includes the key that changed in `userInfo`
- Uses `OSLog` for logging
- A function to migrate your `UserDefaults` instance to `TinyStorage`

## Limitations

Unlike `UserDefaults`, `TinyStorage` does not support mixed collections, so if you have a bunch of strings, dates, and integers all in the same array in `UserDefaults` without boxing them in a shared type, `TinyStorage` won't work. Same situation with dictionaries, you can use them fine with `TinyStorage` but the key and value must both be a `Codable` type, so you can't use `[String: Any]` for instance where each string key could hold a different type of value.

## Installation

Simply add a **Swift Package Manager** dependency for https://github.com/christianselig/TinyStorage.git

## Usage

First, either initialize an instance of `TinyStorage` or create a singleton and choose firstly where you want the file on disk to live, and secondly the name of the directory that will be created to house the backing plist file (handy if you want to create multiple TinyStorage instances, just give each a different `name`!). To keep with `UserDefaults` convention I normally create a singleton for the app container:

```swift
extension TinyStorage {
    static let appGroup: TinyStorage = {
        let appGroupID = "group.com.christianselig.example"
        let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)!
        return .init(insideDirectory: containerURL, name: "tiny-storage-general-prefs")
    }()
}
```

(You can store it wherever you see fit though, in `URL.documentsDirectory` is also an idea for instance!)

Then, decide how you want to reference your keys, similar to `UserDefaults` you can use raw strings, but I recommend a more strongly-typed approach, where you simply conform a type to `TinyStorageKey` and return a `var rawValue: String` and then you can use it as a key for your storage without worrying about typos. If you're using something like an `enum`, making it a `String` enum gives you this for free, so no extra work!

After that you can simply read/write values in and out of your `TinyStorge` instance:

```swift
enum AppStorageKeys: String, TinyStorageKey {
    case likesIceCream
    case pet
    case hasBeatFirstLevel
}

// Read
let pet: Pet? = TinyStorage.appGroup.retrieve(type: Pet.self, forKey: AppStorageKeys.pet)

// Write
TinyStorage.appGroup.store(true, forKey: AppStorageKeys.likesIceCream)
```

(If you have some really weird type or don't want to conform to `Codable`, just convert the type to `Data` through whichever means you prefer and store *that*, as `Data` itself is `Codable`.)

If a value is not present in storage, attempts to retrieve it will always return `nil`. This is in contrast to `UserDefaults` where some primitives like Int or Bool will return 0 or false respectively when not present, rather than `nil`.

If you want to use it in SwiftUI and have your view automatically respond to changes for an item in your storage, you can use the `@TinyStorageItem` property wrapper. Simply specify your storage, the key for the item you want to access, and specify a default value.

```swift
@TinyStorageItem(key: AppStorageKey.pet, storage: .appGroup)
var pet: = Pet(name: "Boots", species: .fish, hasLegs: false)

var body: some View {
    Text(pet.name)
}
```

You can even use Bindings to automatically read/write.

```swift
@TinyStorageItem(key: AppStorageKeys.message, storage: .appGroup)
var message: String = ""

var body: some View {
    VStack {
        Text("Stored Value: \(message)")
        TextField("Message", text: $message)
    }
}
```

It also addresses some of the annoyances of `@AppStorage`, such as not being able to store collections:

```swift
@TinyStorageItem(key: "names", storage: .appGroup)
var names: [String] = []
```

Or better support for optional values:

```swift
@TinyStorageItem(key: "nickname", storage: .appGroup)
var nickname: String? = nil // or "Cool Guy"
```

You can also migrate from a `UserDefaults` instance to `TinyStorage` with a handy helper function:

```swift
let keysToMigrate = ["favoriteIceCream", "appFontSize", "useCustomTheme", "lastFetchDate"]
TinyStorage.appGroup.migrate(userDefaults: .standard, keys: keysToMigrate, overwriteIfConflict: true)
```

(Read the `migrate` function documentation for more details.)

If you want to migrate multiple keys manually or store a bunch of things at once, rather than a bunch of single `store` calls you can consolidate them into one call with `bulkStore` which will only write to disk the once:

```swift
TinyStorage.appGroup.bulkStore(items: [
    AppStorageKeys.pet: pet,
    AppStorageKeys.theme: "sunset"
], skipKeyIfAlreadyPresent: false)
```

(`skipKeyIfAlreadyPresent` when set to `true` creates an API akin to `registerDefaults` from `UserDefaults`.)

Happy storage and hope you enjoy! 💾