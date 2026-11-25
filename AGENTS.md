# Versioning

- Keep the official version in `Resources/Info.plist` unchanged during feature development. Change it only when the user explicitly requests an official version bump.
- For a new feature-development DMG, increment `NookletBetaNumber`. The build script names these packages `Nooklet-<official-version>-beta.<number>-<arch>.dmg`. `CFBundleVersion` is the internal build number.
- When the user requests a stable release, remove `NookletBetaNumber` from the release build.
