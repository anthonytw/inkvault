# Quick voice notes

One tap starts a voice note: from a Lock Screen or Home Screen widget, the
Control Center control (also offered to the Action button), or Siri and
Shortcuts ("Record a Sempere voice note"). Stopping it seals the audio into
the vault's inbox, encrypted. The vault is not unlocked and Face ID is not
asked; the device may even be locked. The next time the vault is unlocked on
any device, each voice note becomes a note in the inbox notebook ("Inbox",
configurable), titled with its date and time, holding the recording and,
when it is ready, its transcript. Format: `format.md` §11. Code: core
`Sources/Sempere/CaptureInbox.swift`, CLI `sempere inbox`, app
`QuickCapture.swift`, `AppModel+Inbox.swift`, `SempereShared/` (intents) and
`SempereWidgets/` (widget extension).

## Why not "write a blob and a delta directly"

The request was to write the age-encrypted blob and a delta revision
directly, needing only the public recipients. Age encryption needs only the
recipients, but the format's integrity layer needs the vault secret:

- every revision body carries HMAC-SHA256(vaultSecret, …) (§4);
- every blob's file name is HMAC-SHA256(vaultSecret, sha256) (§8.1.2).

The secret is age-encrypted to the recipients, so a device that cannot
decrypt cannot write a valid revision or blob. There were two ways to
capture anyway:

1. **Keep the vault secret on the device, outside Face ID** (Keychain,
   readable after the first unlock), and write ordinary revisions. That gives
   whoever extracts it (a forensic dump of a phone after its first unlock,
   malware running as the app) the per-device summary and drawing caches
   (§10, §10.1). Those hold titles, recognised text and the drawings of
   recently opened notes. It also lets them forge revisions into any note.
   The caches are protected by Face ID today; this would weaken all of it.
2. **A capture key and an inbox (chosen).** The device keeps a key derived
   from the secret that can only *add voice notes to the inbox*. Captures are
   sealed into `inbox/`, and a device that can read the vault adopts them as
   ordinary revisions. Nothing a user can see changes: a capture can only be
   read by a device that can unlock the vault, and adoption happens exactly
   then.

The maintainer may prefer option 1's simpler mechanics; that is an open
question on the PR.

## Threat model

Assets: the content of voice notes (audio, transcript), the rest of the
vault, and the vault's integrity.

| Adversary | What they get |
| --- | --- |
| Storage (iCloud, a WebDAV host, a stolen backup) | Inbox files are age-encrypted to the recipients. Without the capture key they cannot add a capture that verifies. They see that captures exist, their sizes and times. |
| A thief with the locked device, before its first unlock after boot | Nothing. The profile is a Keychain item readable only after the first unlock, and no audio is on disk. |
| Forensic extraction after the first unlock (or code running as the app) | The capture profile: public recipients (public anyway) and the capture key. With it they can put forged voice notes in the inbox; they show up in the inbox notebook, attributed to a device id. They cannot read any capture, any note, or the caches, and cannot change existing notes. A voice note being recorded or sealed at that moment is plaintext in the app's container until it is sealed (seconds after it stops). |
| Someone using the unlocked device | They can record voice notes, which is the feature. They cannot listen to past ones without unlocking the vault. |
| A removed device (its key taken off the vault) | Removing a recipient rotates the vault secret (§3.3), so the old capture key no longer verifies. Captures already in the inbox at that moment are re-tagged and re-encrypted by the recipient change (`format.md` §3.3.1), so they are still adopted, and the removed key cannot open them any more; its later captures are reported, kept in the inbox and never adopted. Its profile also encrypts to the old recipient list: re-enable quick capture after key changes (the app refreshes the profile at every unlock and right after a key change or a migration on that device; the CLI needs `sempere inbox enable` again). |

### Plaintext audio

- While recording, `AVAudioRecorder` writes the audio to a file in the app's
  container (`Application Support/Sempere/QuickCapture/<id>/`, not backed up).
  It is protected `completeUntilFirstUserAuthentication`: unreadable before
  the device's first unlock after boot, readable afterwards while the device
  is locked. Not `completeUnlessOpen` (what in-note recordings use): its files
  can be written while locked but not reopened once closed until the device is
  unlocked, and a voice note started and stopped on the Lock Screen is
  assembled from its closed segment files and read back to be sealed before
  any unlock; it would fail to seal, and the voice note would be lost.
- On stop, the audio is read into memory, sealed (age, to the recipients),
  and written to the vault inbox or the queue.
- If transcription is on, the transcript is made on device from that file
  (SpeechTranscriber, else SFSpeechRecognizer on device only; never a server)
  and sealed the same way.
- The folder is deleted right after, and also when the system's background
  time runs out. A crash leaves it until the next launch, when it is sealed
  (from the finished 10-minute segments) and deleted.
- The transcript's plaintext lives in memory only.

So no plaintext audio stays on disk beyond the capture itself plus the
seconds it takes to seal and transcribe it.

## Delivery and queueing

The sealed files are written to `<vault>/inbox/` through the vault's bookmark,
as a coordinated write in iCloud Drive. iCloud Drive accepts writes offline
and uploads them later. When the folder cannot be reached (the bookmark is
stale, the folder was moved, it is another vault), the files go to a local
queue (`Application Support/Sempere/CaptureQueue/<vaultId>/`, already
encrypted). They move into the vault when the app becomes active and when
the vault opens.

## Transcription

Voice notes are transcribed on device as they stop, when "Transcribe Voice
Notes" is on (the default once quick voice notes are on). If that cannot
finish (no time in the background, no model yet), the note is transcribed
after adoption, the next time the vault is unlocked on a device with
transcription on. That transcript goes through the normal path: a blob, then
`setRecording`.

## Surfaces

| Surface | How |
| --- | --- |
| Siri, Shortcuts | `StartVoiceNoteIntent` (an `AudioRecordingIntent`) and `StopVoiceNoteIntent`, phrases in `VoiceNoteShortcuts` |
| Action button | Any of the above, or the control |
| Control Center | `VoiceNoteControl` (`ControlWidget`, iOS 18+) |
| Lock Screen, Home Screen | `VoiceNoteWidget` (circular, rectangular, small) |
| While recording | `VoiceNoteLiveActivity`: timer and Stop, on the Lock Screen and in the Dynamic Island (required for `AudioRecordingIntent`) |
| Mac | Shortcuts and Siri (no widgets in the Catalyst build; a menu bar item is future work) |
| CLI | `sempere inbox enable`, `capture`, `transcript`, `list`, `import` (`docs/cli.md`) |

The intents live in `Apps/Sempere/SempereShared/`, which both the app and
the widget extension compile. They always run in the app's process
(`AudioRecordingIntent`, `LiveActivityIntent`); the extension only shows
buttons.

## Not verified yet

- On a device: the Lock Screen path (intent launch while locked, Keychain
  after first unlock, writing to an iCloud Drive folder while locked, the
  Live Activity).
- The widget extension's code signing in a TestFlight build: it needs the
  bundle id `io.github.anthonytw.sempere.widgets` (automatic signing creates
  it).
