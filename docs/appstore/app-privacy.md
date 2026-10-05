# App Privacy answers

App Store Connect → App Privacy. **TODO(user): confirm each answer against the final build.**

## Data collection

**"Do you or your third-party partners collect data from this app?" → No.**

Result on the product page: **Data Not Collected**.

Why this is accurate: Apple defines "collect" as transmitting data off the device in a way that
lets you and/or your third-party partners access it for longer than needed to service the
request in real time. InkVault has no server, sends nothing to the developer, and includes no
third-party SDKs. Notes are encrypted on the device with the user's key and written only to
storage the user picks (Files, iCloud Drive, a user-configured WebDAV server). Those providers
hold ciphertext on the user's behalf; the developer has no access, so this is not data
collection by the app's developer. If a third-party library is ever added that sends data
anywhere (crash reporting, analytics), this answer changes. The app has no tracking, so there is
no App Tracking Transparency prompt and `NSUserTrackingUsageDescription` is not needed.

Other App Store Connect fields:

- Privacy Policy URL: TODO(user): the hosted `privacy-policy.md` URL.
- Tracking: No. Account creation: none (so account deletion requirements do not apply).
- Age rating: expected 4+. TODO(user): answer the questionnaire; WebDAV connects to servers the
  user names, which is not "unrestricted web access" in the Apple sense, but confirm in the form.

## Privacy manifest (`PrivacyInfo.xcprivacy`)

Since May 2024 apps must declare use of "required reason" APIs. TODO(user): add a
`PrivacyInfo.xcprivacy` to the app target (not added here: it is an app resource that must be
checked in Xcode, and the project's file list is folder-synchronized, so dropping the file in
`Apps/InkVault/InkVaultApp/` is enough). Expected content, from what the source uses (re-check
with Xcode's *Product → Archive → Generate Privacy Report* and a grep of `Sources/` and `Apps/`):

- `NSPrivacyTracking` = false; `NSPrivacyTrackingDomains` empty; `NSPrivacyCollectedDataTypes`
  empty array (matches "Data Not Collected").
- `NSPrivacyAccessedAPICategoryUserDefaults`, reason `CA92.1` (the app stores its own settings in
  `UserDefaults`/`@AppStorage`: column layout, eraser choice).
- `NSPrivacyAccessedAPICategoryFileTimestamp`, reason `C617.1` (file times of files inside the
  app container) and/or `3B52.1` (files the user grants access to), for the vault browser and
  `FileManager` attribute reads; likely also `DiskSpace` only if free space is queried (not
  expected).
- Package dependencies (swift-crypto, swift-argument-parser) ship or need their own manifests;
  swift-crypto 3.x declares one. Verify in the archive's privacy report.
