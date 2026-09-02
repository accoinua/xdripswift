package tk.glucodata.drivers.sibionics

internal class ByteArrayOutputStream {
    private val data = ArrayList<Byte>()
    fun append(value: Byte) { data.add(value) }
    fun append(values: ByteArray) { values.forEach(data::add) }
    fun toByteArray(): ByteArray = data.toByteArray()
}

internal class DataOutputStream(private val target: ByteArrayOutputStream) {
    fun writeInt(value: Int) {
        target.append((value ushr 24).toByte())
        target.append((value ushr 16).toByte())
        target.append((value ushr 8).toByte())
        target.append(value.toByte())
    }
    fun writeFloat(value: Float) = writeInt(value.toRawBits())
    fun write(values: ByteArray) = target.append(values)
}

internal class ByteArrayInputStream(internal val data: ByteArray) {
    internal var position = 0
}

internal class DataInputStream(private val source: ByteArrayInputStream) {
    fun readInt(): Int {
        require(available() >= 4)
        var result = 0
        repeat(4) { result = (result shl 8) or (source.data[source.position++].toInt() and 0xff) }
        return result
    }
    fun readFloat(): Float = Float.fromBits(readInt())
    fun readFully(target: ByteArray) {
        require(available() >= target.size)
        source.data.copyInto(target, 0, source.position, source.position + target.size)
        source.position += target.size
    }
    fun available(): Int = source.data.size - source.position
}

internal inline fun <T, R> T.use(block: (T) -> R): R = block(this)
