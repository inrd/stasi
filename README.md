# Stasi

A macOS menu bar recorder for the system's audio output. One click, then a
peak-normalized WAV lands in the folder you chose.

Built for sampling: WAV only, 24-bit, normalized to −1.0 dBFS. No virtual audio
driver, no admin install, no screen access.

## Install

```sh
./scripts/install.sh        # build, sign, copy to /Applications, launch
```

Or build and run in place:

```sh
./scripts/build.sh
open -n build/Stasi.app
```

Requires macOS 14.2+ and Xcode 16+ (developed on macOS 26.6 / Xcode 27.1).

### Signing

The build picks the first `Developer ID Application` identity in the keychain,
signs with the hardened runtime and a secure timestamp, and falls back to ad-hoc
when none is found. Override with:

```sh
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./scripts/build.sh
```

The signature is stable across rebuilds, so the **System Audio Recording Only**
grant survives them. This was verified by re-signing an already-granted app from
ad-hoc to Developer ID, and by moving it from `build/` into `/Applications` —
neither triggered a new prompt.

The app is **not notarized**, so `spctl` rejects it as "Unnotarized Developer ID".
That only affects quarantined copies (downloads); locally built apps run fine.
Run `xcrun notarytool` if it ever needs to travel to another Mac.

## First run

1. The menu bar gets a `record.circle` icon.
2. A panel asks where to save WAVs. Cancel it and the menu bar shows
   "Choose output folder…" instead — recording refuses to start without one.
3. First recording triggers the **System Audio Recording Only** permission
   prompt. It lands in *System Settings › Privacy & Security › Screen & System
   Audio Recording*, with a toggle of its own — no screen access is requested.

## How it works

```
tap (float32, device rate, stereo)
  -> private aggregate device (output device is the clock)
  -> temporary float32 CAF      ~/Library/Application Support/Stasi/Temp/
  -> peak scan (vDSP_maxmgv)
  -> gain, capped at +30 dB
  -> 24-bit WAV in the chosen folder
```

Normalization cannot be streamed — you need the whole signal to know the peak —
so the CAF is an intermediate working copy. It is deleted after a successful
save, and kept if normalization fails so a take is never lost. Leftovers older
than 24 h are cleaned at launch.

Silent takes are written unnormalized rather than amplified into noise.

## Behaviour worth knowing

- `AudioDeviceStart` blocks for 2–4 s, so it runs off the main thread and the
  elapsed timer starts only once capture is actually live.
- Silence for more than 2.5 s while recording raises a permission hint, because
  a denied tap delivers zeroed buffers with no error.
- Quitting while recording or saving is safe: `applicationShouldTerminate`
  returns `.terminateLater` and waits for the file to be written.
- **Output device changes** are not hot-swapped. The take is finalized, a notice
  appears, and the next one starts manually. Sample rate and clock source can
  change with the device, so continuing mid-file would need resampling for no
  real benefit.
- **Sleep** finalizes the take before the machine suspends.
- **File size**: a RIFF WAV cannot exceed 4 GiB, so recording rolls into a new
  file before that (~3.7 h of 24-bit stereo at 48 kHz) and keeps going.
- **Disk space** is checked at start (500 MB) and every 5 s while recording
  (200 MB); the take is saved before the volume fills.

## Layout

```
Sources/Stasi/
  App/       StasiApp (MenuBarExtra + Settings), AppDelegate (quit finalize)
  Capture/   SystemAudioTap, TempFloatWriter, WavNormalizer, CaptureStats
  Model/     RecorderModel (state machine), Preferences (folder bookmark)
  Support/   Log, TempStorage
  UI/        MenuBarView, SettingsView
docs/        findings.md — low-level Core Audio/TCC behaviour
```

## Test hook

```sh
open -n build/Stasi.app --args --auto-record 15
open -n build/Stasi.app --args --auto-record 20 --max-wav-bytes 2000000
```

`--auto-record <seconds>` records without touching the UI, then saves.
`--max-wav-bytes` lowers the rollover threshold so the segment-splitting path
can be tested in seconds instead of hours.

### Thread Sanitizer

```sh
./scripts/tsan.sh 15
```

Builds a separate sanitized bundle (`build/Stasi-TSan.app`), records for the
given number of seconds while playing a system sound, and fails if TSan reports
a race. Playback matters: in testing, the tap delivered no callbacks while the
output was silent, so nothing on the audio thread ran.

## Verified

- Capture → WAV → normalize hits −1.0 dBFS exactly (ffmpeg `volumedetect`).
- 24-bit / 48 kHz stereo, duration accurate to ~3 ms over 15 s.
- Quit mid-recording finalizes and saves instead of truncating.
- Switching the default output device mid-take finalizes and saves (tested by
  moving the default output to BlackHole 2ch and back).
- File-size rollover: 3 consecutive segments at a 2 MB threshold, each
  normalized, no gaps beyond the 1 s restart pause.
- Temp working file removed after save.
- Installed from `/Applications` with a Developer ID signature, hardened runtime
  and timestamp; recorded immediately with no permission re-prompt.

## Not verified yet

- The Settings window has not been seen on screen (the popover has).
- The sleep notification itself is unverified; it calls the same finalize path
  that the device-change test exercised.
- A real multi-hour take, and the 4 GiB ceiling at production settings.

## Next

- **M3** — UI polish: error states, empty-state onboarding, optional global
  hotkey, recent-takes list.

Launch at login is explicitly **out of scope**. M4 (stable signing and install)
is done.

