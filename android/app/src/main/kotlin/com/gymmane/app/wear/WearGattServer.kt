package com.gymmane.app.wear

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import androidx.core.content.ContextCompat
import com.gymmane.wear.protocol.Chunker
import com.gymmane.wear.protocol.FrameKind
import com.gymmane.wear.protocol.FrameReader
import com.gymmane.wear.protocol.PhoneHandshake
import com.gymmane.wear.protocol.PhoneHandshakeResult
import com.gymmane.wear.protocol.SecureSession
import com.gymmane.wear.protocol.WearJson
import com.gymmane.wear.protocol.Wire
import java.time.Instant
import kotlinx.serialization.json.JsonObject

/**
 * Phone-side GATT peripheral. It advertises one service, accepts commands on the
 * RX characteristic and pushes states on TX with indications. The link depends
 * on OS bonding: every characteristic asks for an encrypted, MITM-protected
 * peer, and the app adds its own PIN/PSK handshake on top.
 */
class WearGattServer(
    private val context: Context,
    private val prefs: WearPrefs,
    private val onEvent: (Map<String, Any?>) -> Unit,
    private val onCommand: (Map<String, Any?>, (Map<String, Any?>?) -> Unit) -> Unit,
    private val snapshot: () -> String?,
) {
    private val main = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager

    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var rx: BluetoothGattCharacteristic? = null
    private var tx: BluetoothGattCharacteristic? = null

    private var connected: BluetoothDevice? = null
    private var reader = FrameReader()
    private var handshake: PhoneHandshake? = null
    private var session: SecureSession? = null
    private var mtu = 23

    private val queue = ArrayDeque<ByteArray>()
    private var sending = false
    private var closeAfterSend = false
    private var subscribed = false
    private val handshakeTimeout = Runnable {
        if (connected != null && session == null) fail("handshake_timeout")
    }
    private var advertising = false
    private var serviceReady = false
    private var lastSnapshot: String? = null
    private var lastHomeSent: JsonObject? = null
    private var pendingHome: JsonObject? = null
    private var handlingCommands = 0
    private var listeningForUnlock = false
    private val phoneUnlock = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_USER_PRESENT && prefs.serverEnabled) {
                start()
                if (session != null) sendState()
            }
        }
    }

    val supported: Boolean
        get() = Build.VERSION.SDK_INT >= 31 &&
            manager?.adapter != null &&
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)

    private val pairingActive: Boolean
        get() = System.currentTimeMillis() < prefs.pairingUntil && prefs.pairingPin.isNotEmpty()

    fun start(): Boolean {
        if (!supported) {
            WearLinkDiagnostics.log("phone server start unsupported")
            return false
        }
        val adapter = manager?.adapter ?: run {
            WearLinkDiagnostics.log("phone server start no_adapter")
            return false
        }
        if (!adapter.isEnabled) {
            WearLinkDiagnostics.log("phone server start bluetooth_off")
            return false
        }
        if (gattServer != null) {
            if (serviceReady) advertise()
            return true
        }
        val open = manager?.openGattServer(context, callback) ?: return false
        val service = BluetoothGattService(WearUuids.SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val write = BluetoothGattCharacteristic(
            WearUuids.RX,
            BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_WRITE_ENCRYPTED_MITM,
        )
        val notify = BluetoothGattCharacteristic(
            WearUuids.TX,
            BluetoothGattCharacteristic.PROPERTY_INDICATE or BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ_ENCRYPTED_MITM,
        )
        val cccd = BluetoothGattDescriptor(
            CCCD,
            BluetoothGattDescriptor.PERMISSION_READ_ENCRYPTED_MITM or
                BluetoothGattDescriptor.PERMISSION_WRITE_ENCRYPTED_MITM,
        )
        cccd.value = BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
        notify.addDescriptor(cccd)
        service.addCharacteristic(write)
        service.addCharacteristic(notify)
        if (!open.addService(service)) {
            WearLinkDiagnostics.log("phone server add_service_failed")
            open.close()
            return false
        }
        rx = write
        tx = notify
        gattServer = open
        if (!listeningForUnlock) {
            listeningForUnlock = runCatching {
                ContextCompat.registerReceiver(
                    context, phoneUnlock, IntentFilter(Intent.ACTION_USER_PRESENT), ContextCompat.RECEIVER_NOT_EXPORTED,
                )
            }.isSuccess
        }
        WearLinkDiagnostics.log("phone server opened; waiting for service registration")
        emit()
        return true
    }

    fun stop() {
        if (listeningForUnlock) {
            context.unregisterReceiver(phoneUnlock)
            listeningForUnlock = false
        }
        main.removeCallbacks(handshakeTimeout)
        stopAdvertising()
        session = null
        handshake = null
        reader.reset()
        queue.clear()
        pendingHome = null
        handlingCommands = 0
        sending = false
        closeAfterSend = false
        subscribed = false
        val device = connected
        connected = null
        if (device != null) runCatching { gattServer?.cancelConnection(device) }
        runCatching { gattServer?.close() }
        gattServer = null
        serviceReady = false
        rx = null
        tx = null
        emit()
    }

    fun startPairing() {
        if (!start()) return
        advertise()
        emit()
    }

    fun cancelPairing() {
        prefs.clearPairing()
        emit()
    }

    fun updateSnapshot(json: String) {
        lastSnapshot = json
        WearLinkDiagnostics.log(
            "phone native snapshot ${WearLinkDiagnostics.snapshotSummary(json)} " +
                "gattSession=${session != null} connected=${connected != null}",
        )
        if (session != null) sendState()
    }

    @SuppressLint("MissingPermission")
    private fun advertise() {
        if (!supported || !serviceReady || advertising || connected != null) return
        val adapter = manager?.adapter ?: return
        if (!adapter.isEnabled) return
        val le = adapter.bluetoothLeAdvertiser ?: return
        advertiser = le
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(WearUuids.SERVICE))
            .setIncludeDeviceName(false)
            .build()
        advertising = true
        try {
            le.startAdvertising(settings, data, advertiseCallback)
        } catch (_: Exception) {
            advertising = false
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertising() {
        if (!advertising) return
        advertising = false
        runCatching { advertiser?.stopAdvertising(advertiseCallback) }
        advertiser = null
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            onMain {
                advertising = true
                WearLinkDiagnostics.log("phone advertising started")
                emit()
            }
        }

        override fun onStartFailure(errorCode: Int) {
            onMain {
                advertising = false
                WearLinkDiagnostics.log("phone advertising failed code=$errorCode")
                onEvent(statusMap() + ("error" to "advertise_$errorCode"))
            }
        }
    }

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }

    private val callback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            onMain {
                if (service.uuid != WearUuids.SERVICE || gattServer == null) return@onMain
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    WearLinkDiagnostics.log("phone service registration failed status=$status")
                    onEvent(statusMap() + ("error" to "service_$status"))
                    stop()
                    return@onMain
                }
                serviceReady = true
                advertise()
                emit()
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            onMain {
                WearLinkDiagnostics.log(
                    "phone GATT connection status=$status " +
                        "state=${if (newState == BluetoothProfile.STATE_CONNECTED) "connected" else "disconnected"}",
                )
                when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> onConnected(device)
                    BluetoothProfile.STATE_DISCONNECTED -> onDisconnected(device)
                }
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            onMain {
                if (device != connected || !subscribed || characteristic.uuid != WearUuids.RX ||
                    preparedWrite || offset != 0 || value.isEmpty() || value.size > 512
                ) {
                    if (responseNeeded) {
                        gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                    }
                    return@onMain
                }
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
                }
                handleBytes(value)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            onMain {
                val enabled = value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE)
                val disabled = value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)
                val valid = device == connected && descriptor.uuid == CCCD &&
                    descriptor.characteristic.uuid == WearUuids.TX && !preparedWrite &&
                    offset == 0 && (enabled || disabled)
                if (valid) subscribed = enabled
                if (responseNeeded) {
                    val status = if (valid) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE
                    gattServer?.sendResponse(device, requestId, status, offset, null)
                }
                if (valid && disabled && session != null) fail("indications_disabled")
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic,
        ) {
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, ByteArray(0))
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            onMain { if (device == connected) this@WearGattServer.mtu = mtu.coerceAtLeast(23) }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            onMain {
                if (device != connected) return@onMain
                sending = false
                WearLinkDiagnostics.log(
                    "phone indication completed status=$status remainingChunks=${queue.size}",
                )
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    queue.clear()
                    fail("indication_$status")
                    return@onMain
                }
                pump()
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun onConnected(device: BluetoothDevice) {
        if (device.bondState != BluetoothDevice.BOND_BONDED) {
            onEvent(statusMap() + ("error" to "not_bonded"))
            runCatching { gattServer?.cancelConnection(device) }
            return
        }
        if (connected != null && connected?.address != device.address) {
            runCatching { gattServer?.cancelConnection(device) }
            return
        }
        connected = device
        session = null
        lastHomeSent = null
        pendingHome = null
        handlingCommands = 0
        subscribed = false
        main.removeCallbacks(handshakeTimeout)
        val timeout = if (pairingActive) 125_000L else 15_000L
        main.postDelayed(handshakeTimeout, timeout)
        reader = FrameReader()
        queue.clear()
        sending = false
        closeAfterSend = false
        mtu = 23
        handshake = PhoneHandshake(
            phoneName = phoneName(),
            pskFor = { prefs.pskFor(it) },
            pairingPin = { if (pairingActive) prefs.pairingPin else null },
            onPaired = { id, name, psk -> prefs.savePsk(id, name, psk) },
            onPairingFailure = { prefs.notePairingFailure() },
            // Writes and subscription are already protected by Android's
            // encrypted, MITM-authenticated GATT permissions.
            allowBondedPairing = { pairingActive && device.bondState == BluetoothDevice.BOND_BONDED },
        )
        stopAdvertising()
        emit()
    }

    private fun onDisconnected(device: BluetoothDevice) {
        if (connected?.address != device.address) return
        connected = null
        subscribed = false
        main.removeCallbacks(handshakeTimeout)
        session = null
        handshake = null
        reader.reset()
        queue.clear()
        sending = false
        closeAfterSend = false
        pendingHome = null
        handlingCommands = 0
        if (prefs.serverEnabled) advertise()
        WearLinkDiagnostics.log("phone GATT peer disconnected; advertising=${prefs.serverEnabled}")
        emit()
    }

    private fun handleBytes(bytes: ByteArray) {
        val frames = try {
            reader.feed(bytes)
        } catch (_: Exception) {
            fail("bad_frame")
            return
        }
        for (frame in frames) {
            WearLinkDiagnostics.log(
                "phone received frame kind=${frame.kind} bytes=${frame.payload.size}",
            )
            when (frame.kind) {
                FrameKind.HANDSHAKE -> handleHandshake(frame.payload)
                FrameKind.SECURE -> handleSecure(frame.payload)
            }
        }
    }

    private fun handleHandshake(payload: ByteArray) {
        val current = handshake ?: return fail("no_handshake")
        val message = try {
            WearJson.parse(payload)
        } catch (_: Exception) {
            return fail("bad_handshake")
        }
        when (val result = current.onMessage(message)) {
            is PhoneHandshakeResult.Reply -> {
                WearLinkDiagnostics.log("phone handshake reply messages=${result.messages.size} close=${result.close}")
                result.messages.forEach { sendHandshake(it) }
                if (result.close) disconnectWhenDrained()
            }
            is PhoneHandshakeResult.Established -> {
                session = result.session
                handshake = null
                main.removeCallbacks(handshakeTimeout)
                prefs.lastWatchName = result.watchName
                if (result.pairedNow) prefs.clearPairing()
                WearLinkDiagnostics.log(
                    "phone handshake established pairedNow=${result.pairedNow} " +
                        "snapshotAvailable=${lastSnapshot != null}",
                )
                emit()
                sendState()
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
            "command" -> {
                val map = WearJson.toMap(opened.data)
                val commandSession = current
                handlingCommands++
                WearLinkDiagnostics.log(
                    "phone received command action=${map["action"] as? String ?: "unknown"}",
                )
                onCommand(map) { ack ->
                    onMain {
                        if (session !== commandSession) return@onMain
                        handlingCommands--
                        if (ack != null) {
                            WearLinkDiagnostics.log(
                                "phone command ack ok=${ack["ok"]} code=${ack["code"]} rev=${ack["rev"]}",
                            )
                            sendSecure("ack", WearJson.fromAny(ack) as? JsonObject ?: emptyObject())
                        } else {
                            sendSecure("ack", ackFor(map, "error"))
                        }
                    }
                }
            }
            "bye" -> disconnectWhenDrained()
        }
    }

    private fun ackFor(command: Map<String, Any?>, code: String): JsonObject {
        val id = (command["id"] as? String) ?: ""
        return WearJson.objectOf {
            put("id", WearJson.text(id))
            put("ok", WearJson.bool(false))
            put("rev", WearJson.number(0))
            put("code", WearJson.text(code))
        }
    }

    private fun emptyObject(): JsonObject = WearJson.objectOf {}

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

    private fun sendState() {
        val json = lastSnapshot ?: snapshot() ?: run {
            WearLinkDiagnostics.log("phone state send skipped: no snapshot")
            return
        }
        val data = try {
            WearJson.parse(json)
        } catch (_: Exception) {
            WearLinkDiagnostics.log("phone state send failed: snapshot parse")
            return
        }
        WearLinkDiagnostics.log("phone sending state ${WearLinkDiagnostics.snapshotSummary(json)}")
        val home = data["home"] as? JsonObject
        pendingHome = home?.takeIf { it != lastHomeSent }
        sendSecure("state", if (home == null) data else JsonObject(data - "home"))
    }

    private fun sendFrame(kind: FrameKind, payload: ByteArray) {
        val frame = try {
            Wire.encode(kind, payload)
        } catch (_: Exception) {
            WearLinkDiagnostics.log("phone frame rejected: too large")
            fail("frame_too_large")
            return
        }
        queue.addAll(Chunker.split(frame, Chunker.gattPayloadSize(mtu)))
        pump()
    }

    @SuppressLint("MissingPermission")
    private fun pump() {
        if (sending) return
        val device = connected ?: return
        val server = gattServer ?: return
        val characteristic = tx ?: return
        val chunk = queue.removeFirstOrNull()
        if (chunk == null) {
            if (closeAfterSend) {
                closeAfterSend = false
                runCatching { server.cancelConnection(device) }
            } else if (handlingCommands == 0) {
                val home = pendingHome ?: return
                pendingHome = null
                lastHomeSent = home
                sendSecure("home", home)
            }
            return
        }
        sending = true
        val sent = try {
            if (Build.VERSION.SDK_INT >= 33) {
                server.notifyCharacteristicChanged(device, characteristic, true, chunk) ==
                    BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                characteristic.value = chunk
                @Suppress("DEPRECATION")
                server.notifyCharacteristicChanged(device, characteristic, true)
            }
        } catch (_: Exception) {
            false
        }
        if (!sent) {
            sending = false
            WearLinkDiagnostics.log("phone indication start failed queued=${queue.size}")
            queue.clear()
            fail("notify_failed")
        } else {
            WearLinkDiagnostics.log("phone indication started queued=${queue.size}")
        }
    }

    private fun disconnectWhenDrained() {
        closeAfterSend = true
        if (!sending && queue.isEmpty()) {
            closeAfterSend = false
            val device = connected
            if (device != null) runCatching { gattServer?.cancelConnection(device) }
        }
    }

    private fun fail(reason: String) {
        onEvent(statusMap() + ("error" to reason))
        disconnectWhenDrained()
    }

    private fun phoneName(): String = Build.MODEL?.takeIf { it.isNotBlank() } ?: "GymMane Phone"

    fun statusMap(): Map<String, Any?> {
        val pairing = pairingActive
        val state = when {
            !supported -> "unsupported"
            !prefs.serverEnabled -> "disabled"
            session != null -> "connected"
            pairing -> "pairing"
            connected != null -> "connecting"
            else -> "idle"
        }
        return mapOf(
            "supported" to supported,
            "enabled" to prefs.serverEnabled,
            "state" to state,
            "deviceName" to prefs.lastWatchName.ifBlank { connectedName() },
            "address" to (connected?.address ?: ""),
            "error" to "",
            "pairingCode" to if (pairing) prefs.pairingPin else "",
            "pairedCount" to prefs.keyCount(),
            "pairingUntil" to if (pairing) Instant.ofEpochMilli(prefs.pairingUntil).toString() else "",
            "sdk" to Build.VERSION.SDK_INT,
        )
    }

    @SuppressLint("MissingPermission")
    private fun connectedName(): String {
        val device = connected ?: return ""
        return runCatching { device.name ?: "" }.getOrDefault("")
    }

    private fun emit() {
        onEvent(statusMap())
    }

    companion object {
        private val CCCD = java.util.UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
