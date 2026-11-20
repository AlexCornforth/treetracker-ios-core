# Treetracker iOS Core

## Project Details

&nbsp;

## Usage

### Cocoapods

&nbsp;

## Project Setup

### XcodeGen
This project uses XcodeGen to generate the project file. 

Install [XcodeGen](https://github.com/yonaskolb/XcodeGen)

Generate the project `xcodegen generate`

### Bundler
This project uses bundler (https://bundler.io/) to manage cocoapods. Use `bundle exec` when using these dependencies.

Install with `gem install bundler`

Run `bundle install` to install cocoapods, fastlane and CocoapodsKeys.

### CocoaPods
Dependencies are managed using [CocoaPods](https://guides.cocoapods.org/) and are checked into to repository.

### SwiftLint
[SwiftLint](https://github.com/realm/SwiftLint) is used to keep the codebase consistent. Rules can be configured or disabled in the [.swiftlint.yml](.swiftlint.yml) file.

&nbsp;

## Uploads

The SDK can upload in two pack formats, chosen with `TreetrackerSDK.Configuration(uploadFormat:)`:

- `.v2` (default): the format Android uses. It uploads separate JSON bundles to the batch-uploads bucket, in this order:
  1. `device_configurations`
  2. `wallet_registrations`
  3. `sessions`
  4. `captures`
  5. `tracks`

  A planter check-in (`PlanterIdentification`) is a v2 session. The code is in `Services/Uploads/V2/`, built with async/await (`AsyncUploadManager`, `V2UploadPipeline`).
- `.v1`: the original `trees` / `registrations` bundles, using the Operation-based `UploadManager`. It is unchanged and kept as a fallback.

The v2 uploader is built for planters who capture offline and upload a large backlog later:
- Trees go 50 per bundle, and up to 4 photos upload at once.
- Transient network errors are retried twice.
- The run stops early when the device goes offline, and resumes where it stopped on the next press.
- Local photos are deleted once their bundle has uploaded.

### Core Data model versions

`Resources/TreeTracker.xcdatamodeld` contains `TreeTracker.xcdatamodel` (version 1) and `TreeTracker 2.xcdatamodel`. `.xccurrentversion` points at the current one.

Existing stores are migrated in place with lightweight migration. So:
- Never edit an old version.
- Only make additive, optional changes in a new version.
- Run `MigrationTests` before shipping.

## Tests

```
xcodegen generate
bundle exec pod install
xcodebuild test -workspace treetracker-core.xcworkspace -scheme Treetracker-Core -destination 'platform=iOS Simulator,name=iPhone 15' -enableThreadSanitizer YES
```

The tests use Swift Testing (Xcode 16 or later) and never touch the network: S3 is replaced with recording fakes.

## Minimum iOS version
iOS 13 (needed for Swift concurrency).

## Deployment
TBC

&nbsp;

## Contributing

See [Contributing in the Development-Overview README](https://github.com/Greenstand/Development-Overview/blob/master/README.md)

Join #ios_treetracker in the slack workspace

Review the project board for current priorities TBC

Please review the [issue tracker](https://github.com/Greenstand/treetracker-ios-core/issues) here on this github repository

Check out the cool [roadmap](https://github.com/Greenstand/Development-Overview/blob/master/Roadmap.md)

All contributions should be submitted as pull requests against the master branch in this github repository. https://github.com/Greenstand/treetracker-ios-core
