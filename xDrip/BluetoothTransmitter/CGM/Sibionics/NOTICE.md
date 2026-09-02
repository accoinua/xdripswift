# Chinese SIBIONICS GS1 algorithm provenance

`Resources/sibionics-v115g.js` is a generated Kotlin/JS production bundle of
the managed `SibionicsExactV115GCore` and `SibionicsExactV115GClip` sources from
JugglucoNG, commit `52d4fe0684b71f003ca1576bc605ec5fb165ce48`.

Both JugglucoNG and xdripswift are distributed under GPL-3.0. The bundle is
loaded locally through Apple's JavaScriptCore framework; it makes no network
request and is not the Android vendor ELF.

The port has deterministic JVM-to-JavaScript parity tests. That establishes
implementation parity with the managed source, not clinical validation of the
recovered algorithm.
