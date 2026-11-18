package com.gymmane.app.wear

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.gymmane.wear.protocol.Chunker
import com.gymmane.wear.protocol.FrameKind
import com.gymmane.wear.protocol.FrameReader
import com.gymmane.wear.protocol.SecureSession
import com.gymmane.wear.protocol.WatchHandshake
import com.gymmane.wear.protocol.WatchHandshakeResult
import com.gymmane.wear.protocol.WearJson
import com.gymmane.wear.protocol.Wire
import java.util.UUID
import kotlin.math.min
import kotlinx.serialization.json.JsonObject

/**
 * Watch-side GATT client. It never scans: the user picks an already bonded phone
 * from the system list, then the client connects to it and runs the shared
 * PIN/PSK handshake on the encrypted link. Commands are sent once and the
 * resulting ack is delivered back to Dart.
 */
class WearGattClient(
    context: Context,
    private val prefs: WearPrefs,
    private val onEvent: (Map<String, Any?>) -> Unit,
    private val onState: (Map<String, Any?>) -> Unit,
    private val onAck: (Map<String, Any?>) -> Unit,
    private val onPinRequired: (String) -> Unit,
) {
    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val manager = app.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager

    private var gatt: BluetoothGatt? = null
    private var rx: BluetoothGattCharacteristic? = null
    private var tx: BluetoothGattCharacteristic? = null
    private var reader = FrameReader()
    private var handshake: WatchHandshake? = null
    private var session: SecureSession? = null
    private var mtu = 23

    private val queue = ArrayDeque<ByteArray>()
    private var sending = false
    private var discoverStarted = false
    private var indicationReady = false
    private var wantConnected = false
    private var retryAttempt = 0
    private var lastError = ""
    private var connectStartedAt = 0L

    private val retry = Runnable { connect() }

    val supported: Boolean
        get() = Build.VERSION.SDK_INT >= 31 &&
            manager?.adapter != null &&
            app.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)

    fun start(address: String, name: String): Map<String, Any?> {
        if (!supported) return statusMap()
        prefs.clientEnabled = true
        prefs.phoneAddress = address
        if (name.isNotBlank()) prefs.phoneName = name
        wantConnected = true
        retryAttempt = 0
        lastError = ""
        if (gatt != null && session == null && connectStartedAt > 0L &&
            SystemClock.elapsedRealtime() - connectStartedAt >= CONNECTION_STALL_MS
        ) {
            WearLinkDiagnostics.log("watch replacing stalled GATT connection")
            disconnect()
        }
        connect()
        return statusMap()
    }

    fun stop(): Map<String, Any?> {
        prefs.clientEnabled = false
        return shutdown()
    }

    /**
     * Stops for a process/engine teardown without forgetting that the user
     * enabled the link. The next launch can resume the saved phone.
     */
    fun shutdown(): Map<String, Any?> {
        wantConnected = false
        lastError = ""
        main.removeCallbacks(retry)
        disconnect()
        emit()
        return statusMap()
    }

    fun forget(): Map<String, Any?> {
        stop()
        prefs.watchPsk = null
        prefs.phoneAddress = ""
        prefs.phoneName = ""
        emit()
        return statusMap()
    }

    fun submitPin(pin: String): Boolean {
        val current = handshake ?: return false
        val message = current.submitPin(pin) ?: return false
        sendHandshake(message)
        return true
    }

    fun requestState() {
        WearLinkDiagnostics.log("watch sending requestState")
        sendCommand(
            mapOf(
                "id" to UUID.randomUUID().toString(),
                "baseRev" to 0,
                "action" to "requestState",
                "args" to emptyMap<String, Any?>(),
            ),
        )
    }

    fun sendCommand(command: Map<String, Any?>) {
        if (session == null) {
            val id = command["id"] as? String ?: ""
            onAck(mapOf("id" to id, "ok" to false, "rev" to 0, "code" to "offline"))
            return
        }
        val data = WearJson.fromAny(command) as? JsonObject
        if (data == null) {
            val id = command["id"] as? String ?: ""
            onAck(mapOf("id" to id, "ok" to false, "rev" to 0, "code" to "invalid"))
            return
        }
        sendSecure("command", data)
    }

    fun statusMap(): Map<String, Any?> = mapOf(
        "supported" to supported,
        "enabled" to prefs.clientEnabled,
        "state" to when {
            !supported -> "unsupported"
            !prefs.clientEnabled -> "disabled"
            session != null -> "connected"
            wantConnected -> if (lastError.isEmpty()) "connecting" else "error"
            lastError.isNotEmpty() -> "error"
            else -> "idle"
        },
        "deviceName" to prefs.phoneName,
        "address" to prefs.phoneAddress,
        "error" to lastError,
        "pairingCode" to "",
        "sdk" to Build.VERSION.SDK_INT,
        "pinRequired" to (handshake != null && session == null && lastError.isEmpty() && wantConnected),
    )

    @SuppressLint("MissingPermission")
    private fun connect() {
        if (!wantConnected) return
        if (gatt != null) return
        val adapter = manager?.adapter ?: run {
            lastError = "no_adapter"
            emit()
            return
        }
        if (!adapter.isEnabled) {
            lastError = "bluetooth_off"
            emit()
            return
        }
        val address = prefs.phoneAddress
        if (address.isBlank()) {
            lastError = "no_phone"
            emit()
            return
        }
        val device = try {
            adapter.getRemoteDevice(address)
        } catch (_: Exception) {
            lastError = "bad_address"
            emit()
            return
        }
        if (device.bondState != BluetoothDevice.BOND_BONDED) {
            lastError = "not_bonded"
            emit()
            return
        }
        lastError = ""
        emit()
        connectStartedAt = SystemClock.elapsedRealtime()
        gatt = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(app, false, callback, BluetoothDevice.TRANSPORT_LE)
            } else {
                device.connectGatt(app, false, callback)
            }
        } catch (_: Exception) {
            lastError = "connect_failed"
            emit()
            scheduleRetry()
            null
        }
    }

    @SuppressLint("MissingPermission")
    private fun disconnect() {
        val current = gatt
        gatt = null
        rx = null
        tx = null
        session = null
        handshake = null
        reader.reset()
        queue.clear()
        sending = false
        discoverStarted = false
        indicationReady = false
        connectStartedAt = 0L
        if (current != null) {
            runCatching { current.disconnect() }
            runCatching { current.close() }
        }
    }

    private fun scheduleRetry() {
        if (!wantConnected) return
        main.removeCallbacks(retry)
        val delay = min(30_000L, 2_000L shl min(retryAttempt, 4))
        retryAttempt += 1
        main.postDelayed(retry, delay)
    }

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            onMain {
                if (gatt !== this@WearGattClient.gatt) {
                    runCatching { gatt.close() }
                    return@onMain
                }
                WearLinkDiagnostics.log(
                    "watch GATT connection status=$status " +
                        "state=${if (newState == BluetoothProfile.STATE_CONNECTED) "connected" else "disconnected"}",
                )
                if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                    retryAttempt = 0
                    lastError = ""
                    discoverStarted = false
                    indicationReady = false
                    session = null
                    handshake = null
                    reader.reset()
                    queue.clear()
                    sending = false
                    mtu = 23
                    emit()
                    if (!gatt.requestMtu(517)) discover(gatt)
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    val failed = status != BluetoothGatt.GATT_SUCCESS
                    disconnect()
                    if (failed && lastError.isEmpty()) lastError = "disconnect_$status"
                    emit()
                    scheduleRetry()
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            onMain {
                if (gatt !== this@WearGattClient.gatt) return@onMain
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    this@WearGattClient.mtu = mtu.coerceAtLeast(23)
                }
                WearLinkDiagnostics.log("watch MTU callback status=$status mtu=$mtu effective=${this@WearGattClient.mtu}")
                discover(gatt)
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            onMain {
                if (gatt !== this@WearGattClient.gatt) return@onMain
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    WearLinkDiagnostics.log("watch service discovery failed status=$status")
                    return@onMain fail("discover_$status")
                }
                val service: BluetoothGattService? = gatt.getService(WearUuids.SERVICE)
                if (service == null) {
                    WearLinkDiagnostics.log("watch service discovery missing_service")
                    return@onMain fail("service_missing")
                }
                val write = service.getCharacteristic(WearUuids.RX)
                val read = service.getCharacteristic(WearUuids.TX)
                if (write == null || read == null) {
                    WearLinkDiagnostics.log("watch service discovery missing_characteristic")
                    return@onMain fail("characteristic_missing")
                }
                WearLinkDiagnostics.log("watch service discovered; enabling indications")
                rx = write
                tx = read
                if (!gatt.setCharacteristicNotification(read, true)) {
                    return@onMain fail("notify_failed")
                }
                val cccd = read.getDescriptor(CCCD) ?: return@onMain fail("cccd_missing")
                @Suppress("DEPRECATION")
                cccd.value = BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                @Suppress("DEPRECATION")
                val queued = gatt.writeDescriptor(cccd)
                if (!queued) fail("cccd_write_failed")
            }
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) {
            onMain {
                if (gatt !== this@WearGattClient.gatt) return@onMain
                if (descriptor.uuid != CCCD) return@onMain
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    WearLinkDiagnostics.log("watch indication subscription failed status=$status")
                    return@onMain fail("cccd_$status")
                }
                indicationReady = true
                WearLinkDiagnostics.log("watch indications enabled; starting handshake")
                beginHandshake()
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            onMain {
                if (gatt !== this@WearGattClient.gatt) return@onMain
                if (characteristic.uuid != WearUuids.TX) return@onMain
                handleBytes(value)
            }
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            @Suppress("DEPRECATION")
            val value = characteristic.value ?: return
            onMain {
                if (gatt !== this@WearGattClient.gatt) return@onMain
                if (characteristic.uuid != WearUuids.TX) return@onMain
                handleBytes(value)
            }
        }

    override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            onMain {
                if (gatt !== this@WearGattClient.gatt) return@onMain
                sending = false
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    WearLinkDiagnostics.log("watch write callback failed status=$status")
                    return@onMain fail("write_$status")
                }
                pump()
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun discover(gatt: BluetoothGatt) {
        if (discoverStarted) return
        discoverStarted = true
        if (!gatt.discoverServices()) fail("discover_failed")
    }

    private fun beginHandshake() {
        WearLinkDiagnostics.log("watch handshake start hasStoredKey=${prefs.watchPsk != null}")
        val watch = WatchHandshake(
            watchId = prefs.watchId,
            watchName = prefs.watchName,
            existingPsk = prefs.watchPsk,
            onPaired = { psk -> prefs.watchPsk = psk },
        )
        handshake = watch
        sendHandshake(watch.start())
    }

    private fun handleBytes(bytes: ByteArray) {
        val frames = try {
            reader.feed(bytes)
        } catch (_: Exception) {
            return fail("bad_frame")
        }
        for (frame in frames) {
            WearLinkDiagnostics.log(
                "watch received frame kind=${frame.kind} bytes=${frame.payload.size}",
            )
            when (frame.kind) {
                FrameKind.HANDSHAKE -> handleHandshake(frame.payload)
                FrameKind.SECURE -> handleSecure(frame.payload)
            }
        }
    }

    private fun handleHandshake(payload: ByteArray) {
        val current = handshake ?: return
        val message = try {
            WearJson.parse(payload)
        } catch (_: Exception) {
            return fail("bad_handshake")
        }
        when (val result = current.onMessage(message)) {
            is WatchHandshakeResult.Reply -> result.messages.forEach { sendHandshake(it) }
            is WatchHandshakeResult.NeedPin -> {
                WearLinkDiagnostics.log("watch handshake requires first-pair PIN")
                onPinRequired(result.phoneName)
            }
            is WatchHandshakeResult.Ready -> {
                session = result.session
                connectStartedAt = 0L
                sendHandshake(result.confirm)
                lastError = ""
                WearLinkDiagnostics.log("watch handshake ready; requesting state")
                emit()
                requestState()
            }
            is WatchHandshakeResult.Rejected -> {
                lastError = "rejected_${result.reason}"
                wantConnected = false
                WearLinkDiagnostics.log("watch handshake rejected reason=${result.reason}")
                emit()
                disconnect()
            }
        }
    }

    private fun handleSecure(payload: ByteArray) {
        val current = session ?: return fail("no_session")
        val envelope = try {
            WearJson.parse(payload)
        } catch (_: Exception) {
            return fail("bad_envelope")
        }
        val opened = try {
            current.open(envelope)
        } catch (_: Exception) {
            return fail("bad_mac")
        }
        when (opened.type) {
            "state" -> {
                val data = WearJson.toMap(opened.data)
                WearLinkDiagnostics.log("watch received state ${WearLinkDiagnostics.snapshotSummary(data)}")
                onState(data)
            }
            "ack" -> {
                val data = WearJson.toMap(opened.data)
                WearLinkDiagnostics.log(
                    "watch received ack ok=${data["ok"]} code=${data["code"]} rev=${data["rev"]}",
                )
                onAck(data)
            }
        }
    }

    private fun sendHandshake(message: JsonObject) {
        sendFrame(FrameKind.HANDSHAKE, message.toString().toByteArray(Charsets.UTF_8))
    }

    private fun sendSecure(type: String, data: JsonObject) {
        val current = session ?: return
        val sealed = try {
            current.seal(type, data)
        } catch (_: Exception) {
            return fail("seal_failed")
        }
        sendFrame(FrameKind.SECURE, sealed.toString().toByteArray(Charsets.UTF_8))
    }

    private fun sendFrame(kind: FrameKind, payload: ByteArray) {
        val frame = try {
            Wire.encode(kind, payload)
        } catch (_: Exception) {
            return fail("frame_too_large")
        }
        queue.addAll(Chunker.split(frame, Chunker.gattPayloadSize(mtu)))
        pump()
    }

    @SuppressLint("MissingPermission")
    private fun pump() {
        if (sending) return
        val current = gatt ?: return
        val characteristic = rx ?: return
        val chunk = queue.removeFirstOrNull() ?: return
        sending = true
        val ok = if (Build.VERSION.SDK_INT >= 33) {
            val code = current.writeCharacteristic(
                characteristic,
                chunk,
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
            )
            code == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            characteristic.value = chunk
            @Suppress("DEPRECATION")
            characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            @Suppress("DEPRECATION")
            current.writeCharacteristic(characteristic)
        }
        if (!ok) {
            sending = false
            WearLinkDiagnostics.log("watch write start failed queued=${queue.size}")
            fail("write_failed")
        } else {
            WearLinkDiagnostics.log("watch write started queued=${queue.size}")
        }
    }

    private fun fail(reason: String) {
        lastError = reason
        WearLinkDiagnostics.log("watch GATT client error=$reason")
        emit()
        disconnect()
        scheduleRetry()
    }

    private fun emit() {
        val map = statusMap()
        onMain { onEvent(map) }
    }

    companion object {
        private const val CONNECTION_STALL_MS = 12_000L
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
