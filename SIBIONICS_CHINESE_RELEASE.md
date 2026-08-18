# xDrip Swift — Chinese SIBIONICS GS1 source release

This tree adds direct support for the **Chinese, single-piece SIBIONICS GS1**.
It deliberately does not implement the EU/V120 protocol, SIBIONICS 2, GS3, or
any Trio changes.

## What is included

- direct CoreBluetooth transport over service `FF30`, notify `FF31`, write `FF32`;
- Chinese `AA 55 07` history request and `AA 55 09` data-frame parser;
- Chinese QR/8-character sensitivity decoding;
- the recovered stock v1.1.5G pipeline, executed locally with JavaScriptCore;
- state snapshots and exact history replay after an interrupted app session;
- a Core Data v17 lightweight migration and xDrip transmitter setup entry;
- the Kotlin sources used to produce the bundled JavaScript resource.

No vendor APK, Android native library, cloud request, or Trio source is included.

## Why this implementation path

`chalimov/sibionics_cgm_ha` is useful V116A/ARM64-emulation research, but its own
support table marks the Chinese unencrypted v1.1.5G variant unsupported. Glucore
packages an Android/Kotlin/JNI sensor stack and the proprietary ARM64 libraries,
so it is not a portable iOS algorithm source. For the Chinese-first target, the
source-level JugglucoNG v1.1.5G transcription was therefore the applicable base.

## Build

1. On a Mac with Xcode, open `xdrip.xcworkspace`.
2. Select the `xdrip` scheme.
3. Configure your Apple development team/signing. If needed, put local values in
   `xDripConfigOverride.xcconfig`, which is ignored by Git.
4. Resolve Swift Package dependencies when Xcode asks, then build the `xdrip`
   scheme for an iPhone running iOS 16.2 or later.

The checked-in `sibionics-v115g.js` is already a target resource; rebuilding it
is not required to build the iOS application.

## Sensor setup

In xDrip, add a Bluetooth peripheral of type **SIBIONICS GS1 Chinese**. Enter the
8-character Chinese sensor code, or paste the complete GS1 QR payload. Keep the
official SIBIONICS app disconnected from the sensor while xDrip is connecting.

The sensor must be able to return a continuous one-minute history beginning at
index 1 when no compatible algorithm snapshot exists. If an index gap is found,
xDrip refuses to advance the exact state and requests history again.

Chinese GS1 is request/response based. xDrip polls every 60 seconds while it is
running. Because iOS may suspend ordinary timers in the background, configure
one of xDrip's supported **HeartBeat** peripherals if uninterrupted background
polling is required; a heartbeat now explicitly triggers a Chinese GS1 request.

## Verification status

- Kotlin/JVM reference versus the generated Kotlin/JavaScript exact-core output:
  3,153 generated samples, zero mismatches.
- Snapshot/restore continuation through the same stream: zero mismatches.
- Xcode project structure, source membership, resource membership, Core Data XML,
  and the syntax of all newly added Swift files were checked on Windows.
- A signed Xcode build and live Chinese sensor replay require macOS and real
  hardware and have **not** been run in this environment.

The parity checks establish deterministic equivalence to the recovered managed
source for the tested inputs. They do not constitute clinical validation or
proof that every vendor edge case has been recovered. Do not use this experimental
path as the sole basis for treatment decisions.

## Provenance

The managed algorithm sources came from JugglucoNG commit
`52d4fe0684b71f003ca1576bc605ec5fb165ce48`. The generated resource SHA-256 is:

`EE90A78C0D32A672CAFF9E416D9C9D1B866D9C04354B61CD154674112E75A799`

See `xDrip/BluetoothTransmitter/CGM/Sibionics/NOTICE.md` and
`Tools/SibionicsV115G/LICENSE-JugglucoNG.txt` for licensing and provenance.
