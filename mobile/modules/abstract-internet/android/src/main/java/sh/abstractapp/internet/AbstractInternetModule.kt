package sh.abstractapp.internet

import android.util.Base64
import computer.iroh.*
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.functions.Coroutine
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap

class AbstractInternetModule : Module() {
  private val relay = "https://relay.useabstract.app"
  private val alpn = "abstract/remote/1".toByteArray()
  private val binding = Mutex()
  private var endpoint: Endpoint? = null
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  private data class Stream(val connection: Connection, val stream: BiStream)
  private val streams = ConcurrentHashMap<String, Stream>()
  private fun decode(value: String) = Base64.decode(value, Base64.DEFAULT)
  private fun encode(value: ByteArray) = Base64.encodeToString(value, Base64.NO_WRAP)
  private fun hex(value: ByteArray) = value.joinToString("") { "%02x".format(it.toInt() and 255) }

  private suspend fun register(key: ByteArray) = withContext(Dispatchers.IO) {
    val signer = SecretKey.fromBytes(key)
    try {
      val timestamp = System.currentTimeMillis() / 1000
      val body = JSONObject().put("key", hex(signer.public().toBytes()))
        .put("timestamp", timestamp)
        .put("signature", encode(signer.sign("abstract-relay-register-v1\n$timestamp".toByteArray()).toBytes()))
      val request = URL("$relay/v1/register").openConnection() as HttpURLConnection
      try {
        request.requestMethod = "POST"; request.doOutput = true
        request.connectTimeout = 10000; request.readTimeout = 10000
        request.setRequestProperty("Content-Type", "application/json")
        request.outputStream.use { it.write(body.toString().toByteArray()) }
        check(request.responseCode == 200) { "The internet relay is unavailable. Local connections still work." }
      } finally { request.disconnect() }
    } finally { signer.destroy() }
  }
  private suspend fun bind(key: ByteArray): Endpoint = binding.withLock {
    register(key)
    endpoint?.let { return@withLock it }
    IrohAndroid.installAndroidContext(requireNotNull(appContext.reactContext).applicationContext)
    val ep = Endpoint.bind(EndpointOptions(preset = presetMinimal(), secretKey = key,
      alpns = listOf(alpn), relayMode = RelayMode.customFromUrls(listOf(relay))))
    endpoint = ep
    scope.launch { while (isActive) { delay(30000); runCatching { register(key) } } }
    ep
  }
  override fun definition() = ModuleDefinition {
    Name("AbstractInternet")
    AsyncFunction("connect") Coroutine { key: String, host: String, handle: String ->
      withTimeout(15000) {
        val ep = bind(decode(key))
        val connection = ep.connect(EndpointAddr(EndpointId.fromString(host), relay, emptyList()), alpn)
        try {
          streams[handle] = Stream(connection, connection.openBi())
          hex(ep.id().toBytes())
        } catch (error: Throwable) { connection.close(0, byteArrayOf()); throw error }
      }
    }
    AsyncFunction("read") Coroutine { handle: String, count: Int ->
      require(count in 1..(16 shl 20))
      encode(requireNotNull(streams[handle]) { "Connection closed" }.stream.recv().readExact(count.toUInt()))
    }
    AsyncFunction("write") Coroutine { handle: String, data: String ->
      val bytes = decode(data); require(bytes.size <= (16 shl 20) + 4)
      requireNotNull(streams[handle]) { "Connection closed" }.stream.send().writeAll(bytes)
    }
    AsyncFunction("close") { handle: String -> streams.remove(handle)?.connection?.close(0, byteArrayOf()); Unit }
    OnDestroy {
      streams.values.forEach { it.connection.close(0, byteArrayOf()) }; streams.clear()
      scope.launch { endpoint?.close(); endpoint = null; scope.cancel() }
    }
  }
}
