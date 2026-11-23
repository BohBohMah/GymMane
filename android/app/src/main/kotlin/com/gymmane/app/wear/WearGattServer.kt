package com.gymmane.app.wear

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
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
    private var gattCallback: BluetoothGattServerCallback? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var rx: BluetoothGattCharacteristic? = null
    private var tx: BluetoothGattCharacteristic? = null

    private var connected: BluetoothDevice? = null
    private val reader = FrameReader()
    private var handshake: PhoneHandshake? = null
    private var session: SecureSession? = null
    private var mtu = 23

    private val queue = ArrayDeque<ByteArray>()
    private var sending = false
    private var closeAfterSend = false
    private var disconnecting = false
    private var subscribed = false
    private val handshakeTimeout = Runnable {
        if (connected != null && session == null) fail("handshake_timeout")
    }
    private val indicationTimeout = Runnable { if (sending) fail("indication_timeout") }
    private val disconnectTimeout = Runnable { if (disconnecting) recoverTransport() }
    private var serviceReady = false
    private var lastSnapshot: String? = null
    private var lastHomeSent: JsonObject? = null
    private var pendingHome: JsonObject? = null
    private var handlingCommands = 0
    private var listeningForBluetooth = false
    private var listeningForUnlock = false
    private val retryTransport = Runnable { start() }
    private val registrationTimeout = Runnable {
        if (gattServer != null && !serviceReady) recoverTransport()
    }
    private val bluetoothState = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED || !prefs.serverEnabled) return
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> {
                    closeTransport()
                    emit()
                }
                BluetoothAdapter.STATE_ON -> {
                    closeTransport()
                    start()
                }
            }
        }
    }
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

    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        if (!supported) {
            WearLinkDiagnostics.log("phone server start unsupported")
            return false
        }
        val manager = manager ?: return false
        val adapter = manager.adapter ?: run {
            WearLinkDiagnostics.log("phone server start no_adapter")
            return false
        }
        if (!listenForBluetooth()) return false
        main.removeCallbacks(retryTransport)
        // Android invalidates the GATT server and advertiser when its radio is
        // turned off. Keep observing the adapter so STATE_ON can recreate both.
        if (!adapter.isEnabled) {
            closeTransport()
            emit()
            return true
        }
        if (gattServer != null) {
            if (serviceReady) advertise()
            return true
        }
        val callback = newGattCallback()
        val open = runCatching { manager.openGattServer(context, callback) }.getOrNull()
        if (open == null) {
            scheduleRetry()
            return true
        }
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
        rx = write
        tx = notify
        gattServer = open
        gattCallback = callback
        if (!runCatching { open.addService(service) }.getOrDefault(false)) {
            WearLinkDiagnostics.log("phone server add_service_failed")
            recoverTransport()
            return true
        }
        main.postDelayed(registrationTimeout, 5_000L)
        WearLinkDiagnostics.log("phone server opened; waiting for service registration")
        emit()
        return true
    }

    private fun listenForBluetooth(): Boolean {
        if (!listeningForBluetooth) {
            listeningForBluetooth = runCatching {
                // Android's Bluetooth process sends this protected broadcast.
                ContextCompat.registerReceiver(
                    context, bluetoothState, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
                    ContextCompat.RECEIVER_EXPORTED,
                )
            }.isSuccess
        }
        if (!listeningForBluetooth) return false
        if (!listeningForUnlock) {
            listeningForUnlock = runCatching {
                ContextCompat.registerReceiver(
                    context, phoneUnlock, IntentFilter(Intent.ACTION_USER_PRESENT), ContextCompat.RECEIVER_NOT_EXPORTED,
                )
            }.isSuccess
        }
        return true
    }

    fun stop() {
        if (listeningForBluetooth) {
            context.unregisterReceiver(bluetoothState)
            listeningForBluetooth = false
        }
        if (listeningForUnlock) {
            context.unregisterReceiver(phoneUnlock)
            listeningForUnlock = false
        }
        closeTransport()
        emit()
    }

    @SuppressLint("MissingPermission")
    private fun closeTransport() {
        main.removeCallbacks(retryTransport)
        main.removeCallbacks(registrationTimeout)
        stopAdvertising()
        resetPeer()
        gattCallback = null
        val server = gattServer
        gattServer = null
        runCatching { server?.close() }
        serviceReady = false
        rx = null
        tx = null
    }

    private fun resetPeer() {
        main.removeCallbacks(handshakeTimeout)
        main.removeCallbacks(indicationTimeout)
        main.removeCallbacks(disconnectTimeout)
        connected = null
        session = null
        handshake = null
        reader.reset()
        queue.clear()
        lastHomeSent = null
        pendingHome = null
        handlingCommands = 0
        sending = false
        closeAfterSend = false
        disconnecting = false
        subscribed = false
        mtu = 23
    }

    @SuppressLint("MissingPermission")
    private fun scheduleRetry() {
        main.removeCallbacks(retryTransport)
        if (listeningForBluetooth && prefs.serverEnabled && manager?.adapter?.isEnabled == true) {
            main.postDelayed(retryTransport, 2_000L)
        }
    }

    private fun recoverTransport() {
        closeTransport()
        emit()
        scheduleRetry()
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
        if (!supported || !serviceReady || advertiseCallback != null || connected != null) return
        val adapter = manager?.adapter ?: return
        if (!adapter.isEnabled) return
        val le = adapter.bluetoothLeAdvertiser ?: run {
            scheduleRetry()
            return
        }
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
        val callback = newAdvertiseCallback()
        advertiser = le
        advertiseCallback = callback
        try {
            le.startAdvertising(settings, data, callback)
        } catch (_: Exception) {
            stopAdvertising()
            scheduleRetry()
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertising() {
        val callback = advertiseCallback ?: return
        advertiseCallback = null
        runCatching { advertiser?.stopAdvertising(callback) }
        advertiser = null
    }

    private fun newAdvertiseCallback() = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            onMain {
                if (advertiseCallback !== this) return@onMain
                WearLinkDiagnostics.log("phone advertising started")
                emit()
            }
        }

        override fun onStartFailure(errorCode: Int) {
            onMain {
                if (advertiseCallback !== this) return@onMain
                stopAdvertising()
                scheduleRetry()
                WearLinkDiagnostics.log("phone advertising failed code=$errorCode")
                onEvent(statusMap() + ("error" to "advertise_$errorCode"))
            }
        }
    }

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }

    private fun newGattCallback() = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            onMain {
                if (gattCallback !== this || service.uuid != WearUuids.SERVICE) return@onMain
                main.removeCallbacks(registrationTimeout)
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    WearLinkDiagnostics.log("phone service registration failed status=$status")
                    onEvent(statusMap() + ("error" to "service_$status"))
                    recoverTransport()
                    return@onMain
                }
                serviceReady = true
                advertise()
                emit()
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            onMain {
                if (gattCallback !== this) return@onMain
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
                if (gattCallback !== this) return@onMain
                if (device != connected || disconnecting || !subscribed || characteristic.uuid != WearUuids.RX ||
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
                if (gattCallback !== this) return@onMain
                val enabled = value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE)
                val disabled = value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)
                val valid = device == connected && !disconnecting && descriptor.uuid == CCCD &&
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
            onMain {
                if (gattCallback === this) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, ByteArray(0))
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            onMain {
                if (gattCallback === this && device == connected) {
                    this@WearGattServer.mtu = mtu.coerceAtLeast(23)
                }
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            onMain {
                if (gattCallback !== this || device != connected || !sending) return@onMain
                main.removeCallbacks(indicationTimeout)
                sending = false
                WearLinkDiagnostics.log(
                    "phone indication completed status=$status remainingChunks=${queue.size}",
                )
                if (status != BluetoothGatt.GATT_SUCCESS) {
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
        val peer = connected
        if (peer != null) {
            if (peer != device) runCatching { gattServer?.cancelConnection(device) }
            return
        }
        connected = device
        val timeout = if (pairingActive) 125_000L else 15_000L
        main.postDelayed(handshakeTimeout, timeout)
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
        resetPeer()
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
        if (sending || disconnecting) return
        val device = connected ?: return
        val server = gattServer ?: return
        val characteristic = tx ?: return
        val chunk = queue.removeFirstOrNull()
        if (chunk == null) {
            if (closeAfterSend) {
                disconnectPeer()
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
            WearLinkDiagnostics.log("phone indication start failed queued=${queue.size}")
            fail("notify_failed")
        } else {
            main.postDelayed(indicationTimeout, GATT_CALLBACK_TIMEOUT_MS)
            WearLinkDiagnostics.log("phone indication started queued=${queue.size}")
        }
    }

    private fun disconnectWhenDrained() {
        closeAfterSend = true
        if (!sending && queue.isEmpty()) disconnectPeer()
    }

    @SuppressLint("MissingPermission")
    private fun disconnectPeer() {
        val device = connected ?: return
        if (disconnecting) return
        disconnecting = true
        main.removeCallbacks(handshakeTimeout)
        main.removeCallbacks(indicationTimeout)
        sending = false
        queue.clear()
        session = null
        handshake = null
        emit()
        // Some controllers never report a disconnect after a failed indication.
        main.postDelayed(disconnectTimeout, GATT_CALLBACK_TIMEOUT_MS)
        runCatching { gattServer?.cancelConnection(device) }.onFailure { recoverTransport() }
    }

    private fun fail(reason: String) {
        onEvent(statusMap() + ("error" to reason))
        disconnectPeer()
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
        private const val GATT_CALLBACK_TIMEOUT_MS = 8_000L
        private val CCCD = java.util.UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
