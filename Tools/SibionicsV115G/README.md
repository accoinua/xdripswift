# Rebuilding `sibionics-v115g.js`

This directory contains the Kotlin/JS-compatible source used for xDrip's bundled
Chinese SIBIONICS GS1 v1.1.5G algorithm. It is retained so the generated runtime
resource is reproducible and reviewable.

Requirements: JDK 17, Gradle 8.13, and network access to Maven Central and the
Gradle plugin portal on the first build.

From this directory, run:

```text
gradle jsBrowserProductionWebpack
```

Then copy:

```text
build/kotlin-webpack/js/productionExecutable/sibionics-v115g.js
```

to:

```text
xDrip/BluetoothTransmitter/CGM/Sibionics/Resources/sibionics-v115g.js
```

Expected SHA-256 for the checked-in bundle:

```text
EE90A78C0D32A672CAFF9E416D9C9D1B866D9C04354B61CD154674112E75A799
```

After rebuilding, run `node verify-bundle.js`. It verifies the bundle checksum,
a fixed 3,153-sample output vector, and state snapshot/restore continuation.

The sources were adapted from JugglucoNG commit
`52d4fe0684b71f003ca1576bc605ec5fb165ce48`: JVM data streams were replaced by
equivalent common Kotlin helpers, `System.arraycopy` by `copyInto`, and unsigned
comparisons by Kotlin `UInt`. The algorithm constants and branch logic were not
intentionally changed. `Adapter.kt` supplies the exported JavaScriptCore API,
one-minute display carry, and snapshot envelope used by Swift.
