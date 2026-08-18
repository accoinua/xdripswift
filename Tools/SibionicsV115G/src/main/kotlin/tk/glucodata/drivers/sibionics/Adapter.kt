@file:OptIn(ExperimentalJsExport::class)

package tk.glucodata.drivers.sibionics

import kotlin.math.abs
import kotlin.math.max

internal data class SibionicsChemicalSignal(val mmol: Float, val qualityFlags: Int)

/** JavaScriptCore-facing singleton for the Chinese GS1 v1.1.5G stock algorithm. */
@JsExport
object SibionicsV115G {
    private var core = SibionicsExactV115GCore()
    private var configuredSensitivity = 1.27f
    private var liveDelta = Float.NaN
    private var replayDelta = Float.NaN

    fun reset(sensitivity: Double) {
        configuredSensitivity = sensitivity.toFloat()
        core = SibionicsExactV115GCore(configuredSensitivity)
        liveDelta = Float.NaN
        replayDelta = Float.NaN
    }

    fun process(rawMmol: Double, temperatureC: Double, index: Int, live: Boolean): Double {
        val raw = rawMmol.toFloat()
        if (!raw.isFinite() || raw <= 0f) return Double.NaN
        val candidate = core.process(raw, temperatureC.toFloat(), index)
        val display = if (live) liveValue(raw, candidate) else replayValue(raw, candidate)
        if (!display.isFinite() || display > 35f) {
            if (live) liveDelta = Float.NaN else replayDelta = Float.NaN
            return nativeRound(raw).toDouble()
        }
        return max(display, 0f).toDouble()
    }

    /** Test/provenance API: exact five-minute core output without delta carry. */
    fun processExact(rawMmol: Double, temperatureC: Double, index: Int): Double =
        core.process(rawMmol.toFloat(), temperatureC.toFloat(), index)?.toDouble() ?: Double.NaN

    fun snapshotHex(): String {
        val coreHex = core.snapshot().toHex()
        return configuredSensitivity.toRawBits().toUInt().toString(16).padStart(8, '0') +
            liveDelta.toRawBits().toUInt().toString(16).padStart(8, '0') +
            replayDelta.toRawBits().toUInt().toString(16).padStart(8, '0') + coreHex
    }

    fun restoreHex(value: String): Boolean = runCatching {
        if (value.length < 24 || value.length % 2 != 0) return false
        val sensitivity = Float.fromBits(value.substring(0, 8).toUInt(16).toInt())
        if (sensitivity.toRawBits() != configuredSensitivity.toRawBits()) return false
        val savedLive = Float.fromBits(value.substring(8, 16).toUInt(16).toInt())
        val savedReplay = Float.fromBits(value.substring(16, 24).toUInt(16).toInt())
        if (!validDelta(savedLive) || !validDelta(savedReplay)) return false
        val bytes = value.substring(24).hexToBytes()
        if (!core.restore(bytes)) return false
        liveDelta = savedLive
        replayDelta = savedReplay
        true
    }.getOrDefault(false)

    private fun liveValue(raw: Float, candidate: Float?): Float {
        if (candidate != null && usableCandidate(candidate)) {
            liveDelta = candidate - raw
            return candidate
        }
        val delta = when {
            validFiniteDelta(liveDelta) -> liveDelta
            validFiniteDelta(replayDelta) -> replayDelta
            else -> Float.NaN
        }
        if (!delta.isFinite()) return nativeRound(raw)
        liveDelta = delta
        return nativeRound(raw + delta)
    }

    private fun replayValue(raw: Float, candidate: Float?): Float {
        if (candidate != null && usableCandidate(candidate)) {
            val delta = candidate - raw
            replayDelta = delta
            liveDelta = delta
            return candidate
        }
        return if (validFiniteDelta(replayDelta)) nativeRound(raw + replayDelta) else nativeRound(raw)
    }

    private fun usableCandidate(value: Float) = value.isFinite() && value > 1f && value <= 35f
    private fun validFiniteDelta(value: Float) = value.isFinite() && abs(value) < 15f
    private fun validDelta(value: Float) = value.isNaN() || validFiniteDelta(value)
    private fun nativeRound(value: Float): Float = ((value * 10f + if (value >= 0f) 0.5f else 0f).toInt()) / 10f
    private fun ByteArray.toHex(): String = joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }
    private fun String.hexToBytes(): ByteArray = ByteArray(length / 2) { substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}
