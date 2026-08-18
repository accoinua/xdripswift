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
8-character connection code printed below the GS1 DataMatrix, or paste the
complete GS1 DataMatrix payload. Example:

`9MAE230B`

The DataMatrix carries the GTIN, production and expiry dates, lot, and serial.
For the photographed sensor its serial is `2605069MAE230BFN18`; the printed
connection code is serial characters 7–14. It does not contain a literal BLE
address, and normal setup must not require an Android device.

Across the available labels, the serial layout is
`<6-character lot core><8-character connection code><4-character suffix>`.
The first four characters of the connection code match the suffix of the BLE
advertised name, so xDrip uses them to select the intended sensor automatically.

The sensor must be able to return a continuous one-minute history beginning at
index 1 when no compatible algorithm snapshot exists. If an index gap is found,
xDrip refuses to advance the exact state and requests history again.

Chinese GS1 is request/response based. xDrip polls every 60 seconds while it is
running. Because iOS may suspend ordinary timers in the background, configure
one of xDrip's supported **HeartBeat** peripherals if uninterrupted background
polling is required; a heartbeat now explicitly triggers a Chinese GS1 request.
The lifetime display uses the approximately 24-day extended Chinese operating
window rather than the 14-day vendor-rated duration.

## Verification status

- Kotlin/JVM reference versus the generated Kotlin/JavaScript exact-core output:
  3,153 generated samples, zero mismatches.
- Snapshot/restore continuation through the same stream: zero mismatches.
- GitHub Actions produced a signed TestFlight build, and an iPhone live test
  confirmed FF30 connection, FF31 notifications, and successful FF32 writes.
- The first live build sent zeroes in bytes where Juggluco inserts Android's BLE
  address. The sensor only returned `AA 55 07` echo frames and no `AA 55 09`
  glucose data. The QR does not expose the address. The next diagnostic build
  records iOS advertisement/service data and reads standard Device Information
  characteristics to locate the native iOS identity source without guessing.
- A TestFlight crash report identified teardown in `stopPolling()` during
  `deinit`; the weak-reference registration responsible for that crash has been
  removed, but the fix still requires a live disconnect retest.

The parity checks establish deterministic equivalence to the recovered managed
source for the tested inputs. Until the native iOS request receives and processes
real `AA 55 09` frames, direct sensor support remains experimental and
must not be described as verified. The checks do not constitute clinical
validation. Do not use this path as the sole basis for treatment decisions.

## Provenance

The managed algorithm sources came from JugglucoNG commit
`52d4fe0684b71f003ca1576bc605ec5fb165ce48`. The generated resource SHA-256 is:

`EE90A78C0D32A672CAFF9E416D9C9D1B866D9C04354B61CD154674112E75A799`

See `xDrip/BluetoothTransmitter/CGM/Sibionics/NOTICE.md` and
`Tools/SibionicsV115G/LICENSE-JugglucoNG.txt` for licensing and provenance.
