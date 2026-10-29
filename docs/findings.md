# Implementation findings

Low-level behaviour that shaped the code, kept because each item cost real time
to discover. Most of it is not in Apple's documentation, or is documented
incorrectly.

## Core Audio taps

- Tap format on this machine: 48 kHz, 2 ch, float32, **interleaved**, 8 bytes per
  frame. Read it from `kAudioTapPropertyFormat`; do not assume.
- The tap delivers a fixed **512 frames (~10.7 ms)** per callback.
- `AudioDeviceStart` blocks for **2–4 s** while the aggregate device comes up.
  Never call it on the main thread, and start the elapsed timer only after it
  returns.
- Audio arrives on the IOProc's **input** side, not the output side.
- The aggregate needs the default output device in
  `kAudioAggregateDeviceSubDeviceListKey` as a clock source; a tap-only aggregate
  has no clock.
- **Capture is pre-volume-control.** With the system slider at 19/100, the
  captured peak matched the source file's −3.0 dBFS exactly. Recordings are
  independent of how loud the speakers were — good for sampling.
- Float headroom above 0 dBFS survives capture (one take peaked at 1.3079), so
  normalization can reduce gain instead of clipping.
- **The aggregate's input streams are the sub-devices' inputs first, then the
  taps.** Listing the output device in `kAudioAggregateDeviceSubDeviceListKey`
  therefore puts its inputs ahead of the tap: with BlackHole 2ch as the default
  output, input stream 0 is BlackHole's input, not the tap. Both
  `kAudioDevicePropertyStreamFormat` (input scope) and IOProc buffer 0 then pick
  the wrong stream. The take failed outright: `buffers=2` and every
  `ExtAudioFileWriteAsync` was rejected, leaving an empty CAF.
  `kAudioSubDeviceInputChannelsKey: 0` does **not** help — the HAL still reports
  the device's full channel count. Set `kAudioAggregateDeviceClockDeviceKey` and
  keep the sub-device list empty instead: the clock contributes no streams, so
  the tap is the only input stream.
- The tap keeps its native 48 kHz ASBD inside an aggregate clocked at 44.1 kHz.
  The aggregate resamples the buffers, but the stream format still says 48 kHz.
  Write the file at the aggregate's `kAudioDevicePropertyNominalSampleRate`
  (the clock rate): writing 44.1 kHz frames as 48 kHz turns a 2.000 s tone into
  1.8375 s (44.1/48) and pitches it up.

## Permissions

- `NSAudioCaptureUsageDescription` is mandatory in `Info.plist`. Without it the
  prompt never appears and capture silently yields zeros.
- The grant is audio-only: its own pane ("System Audio Recording Only"), its own
  toggle, no screen access requested.
- The grant **survived** an ad-hoc → Developer ID re-sign and a move from
  `build/` into `/Applications`, with no re-prompt. TCC keys on bundle identifier
  more than on path or signature.
- A denied tap returns zeroed buffers with **no error**, and there is no public
  API to query the permission. Silence detection is the only practical detector.

## ExtAudioFile

- The client `AudioStreamBasicDescription` must set `mFramesPerPacket = 1` and the
  native-endian flag. Otherwise `ExtAudioFileSetProperty` returns `-50`
  (paramErr). Use `kAudioFormatFlagsNativeFloatPacked` rather than hand-rolling
  the flag bits — omitting native endian is the easy mistake.

## AVAudioFile at EOF

Reading at end-of-file returns `NO` rather than a zero-length buffer.

That part is intentional; the SDK header says:

> Starting in macOS 27.0, iOS 27.0, watchOS 27.0, and tvOS 27.0, attempting to
> read beyond the end of the file will return NO and set outError to an NSError
> with domain NSOSStatusErrorDomain and code kAudioFileEndOfFileError.

Two things are wrong with it:

1. **The error is never set.** Calling the Objective-C method directly with a
   file positioned at EOF returns `ok=0 frameLength=0 outError=(null)`. The
   documented `kAudioFileEndOfFileError` (−39) never appears, so Swift surfaces
   `Foundation._GenericObjCError 0`, which prints as the useless `nilError`.
2. **The version gate is wrong.** The behaviour is present on macOS 26.6.2, and
   it does not change when the binary is rebuilt with `LC_BUILD_VERSION sdk=26.0`
   via `vtool` — so it is not a linked-on-or-after SDK gate either.

Rule: never probe for EOF with a full-size read. Bound loops with
`input.length` and `input.framePosition`.

## Threading

Four classes cross the audio/main boundary. `StatsBox` is a plain `Sendable`
class and `AudioDeviceObserver` is main-actor isolated, so both are checked by
the compiler. `TempFloatWriter` and `SystemAudioTap` remain `@unchecked
Sendable` and rely on these rules:

- `SystemAudioTap.start()` and `stop()` are never concurrent and never run on
  the audio thread. `handleIO` is the only audio-thread entry point, and it
  touches only `firstBuffer`, `stats` and `writer`.
- `TempFloatWriter.file` is opened before the IOProc exists and disposed after
  `AudioDeviceStop`, so only the audio thread reads it while capture runs.
- Progress and failure state (`StatsBox`, `TempFloatWriter.progress`) live
  behind `OSAllocatedUnfairLock`. Do not add a mutable property that both
  threads touch.
- `AudioDeviceObserver` is main-actor isolated; the HAL listener block reads the
  device UID on its own queue and hops to the main actor before comparing it.

A take should be recorded with `./scripts/tsan.sh` after touching any of them:
TSan catches the races the compiler cannot see.
