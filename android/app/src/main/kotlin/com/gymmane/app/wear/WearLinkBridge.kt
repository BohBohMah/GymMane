package com.gymmane.app.wear

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter bridge for the direct phone/watch link. It exposes both roles on the
 * same channel: the phone advertises as a GATT peripheral, the watch connects
 * as a GATT client to an already bonded phone. No Internet transport, no Wear
 * Data Layer, no scanning.
 */
object WearLinkBridge {
    const val CHANNEL = "gymmane/wearlink"
    private const val REQUEST = 7412

    private var activity: Activity? = null
    private var channel: MethodChannel? = null
    private var server: WearGattServer? = null
    private var client: WearGattClient? = null
    private var lastJson: String? = null

    private var pendingResult: MethodChannel.Result? = null
    private var pendingAction: (() -> Any?)? = null
    private var pendingAdvertise = true

    fun attach(activity: Activity, channel: MethodChannel) {
        this.activity = activity
        this.channel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startServer" -> ensure(true, result) { startServer() }
                "stop" -> result.success(stopServer())
                "beginPairing" -> ensure(true, result) { beginPairing() }
                "cancelPairing" -> result.success(cancelPairing())
                "forget" -> result.success(forgetServer())
                "status" -> result.success(serverStatus())
                "update" -> {
                    lastJson = call.argument<String>("json")
                    server?.updateSnapshot(lastJson ?: "")
                    result.success(null)
                }
                "requestPermissions" -> {
                    requestPermissions(true)
                    result.success(serverStatus())
                }
                "bondedDevices" -> ensure(false, result) { bondedDevicesList() }
                "startClient" -> {
                    val address = call.argument<String>("address") ?: ""
                    val name = call.argument<String>("name") ?: ""
                    ensure(false, result) { startClient(address, name) }
                }
                "stopClient" -> result.success(stopClient())
                "clientStatus" -> result.success(clientStatus())
                "submitPin" -> {
                    val pin = call.argument<String>("pin") ?: ""
                    result.success(client?.submitPin(pin) ?: false)
                }
                "forgetPhone" -> result.success(forgetPhone())
                "sendCommand" -> {
                    val raw = call.arguments
                    if (raw is Map<*, *>) {
                        val map = raw.entries
                            .filter { it.key is String }
                            .associate { it.key as String to it.value }
                        client?.sendCommand(map)
                        result.success(null)
                    } else {
                        result.error("bad-command", "command must be a map", null)
                    }
                }
                "requestState" -> {
                    client?.requestState()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun detach(activity: Activity) {
        if (this.activity !== activity) return
        server?.stop()
        server = null
        client?.shutdown()
        client = null
        lastJson = null
        pendingResult = null
        pendingAction = null
        channel?.setMethodCallHandler(null)
        channel = null
        this.activity = null
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST) return false
        val result = pendingResult
        val action = pendingAction
        pendingResult = null
        pendingAction = null
        if (result != null) {
            val granted = grantResults.isNotEmpty() &&
                grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            if (granted && action != null) {
                result.success(action())
            } else {
                result.success(deniedMap())
            }
        }
        return true
    }

    private fun ensure(advertise: Boolean, result: MethodChannel.Result, action: () -> Any?) {
        val current = activity
        if (current == null) {
            result.success(unsupportedMap())
            return
        }
        val missing = missing(advertise)
        if (missing.isEmpty()) {
            result.success(action())
            return
        }
        pendingResult?.success(deniedMap())
        pendingResult = result
        pendingAction = action
        pendingAdvertise = advertise
        try {
            current.requestPermissions(missing, REQUEST)
        } catch (_: Exception) {
            pendingResult = null
            pendingAction = null
            result.success(deniedMap())
        }
    }

    private fun requestPermissions(advertise: Boolean) {
        val current = activity ?: return
        val missing = missing(advertise)
        if (missing.isEmpty()) return
        try {
            current.requestPermissions(missing, REQUEST)
        } catch (_: Exception) {
        }
    }

    private fun missing(advertise: Boolean): Array<String> {
        if (Build.VERSION.SDK_INT < 31) return emptyArray()
        val current = activity ?: return emptyArray()
        val list = mutableListOf<String>()
        if (current.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            list += Manifest.permission.BLUETOOTH_CONNECT
        }
        if (advertise &&
            current.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            list += Manifest.permission.BLUETOOTH_ADVERTISE
        }
        return list.toTypedArray()
    }

    private fun isWatch(): Boolean =
        activity?.packageManager?.hasSystemFeature(PackageManager.FEATURE_WATCH) ?: false

    private fun prefs(): WearPrefs? = activity?.let { WearPrefs(it) }

    private fun server(): WearGattServer? {
        val current = activity ?: return null
        server?.let { return it }
        val store = WearPrefs(current)
        val created = WearGattServer(
            context = current.applicationContext,
            prefs = store,
            onEvent = { event -> channel?.invokeMethod("linkEvent", event) },
            onCommand = { command, reply ->
                val target = channel
                if (target == null) {
                    reply(
                        mapOf(
                            "id" to (command["id"] as? String ?: ""),
                            "ok" to false,
                            "rev" to 0,
                            "code" to "offline",
                        ),
                    )
                } else {
                    target.invokeMethod("command", command, object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            reply(asMap(result))
                        }

                        override fun error(code: String, message: String?, details: Any?) {
                            reply(
                                mapOf(
                                    "id" to (command["id"] as? String ?: ""),
                                    "ok" to false,
                                    "rev" to 0,
                                    "code" to "error",
                                    "message" to (message ?: code),
                                ),
                            )
                        }

                        override fun notImplemented() {
                            reply(
                                mapOf(
                                    "id" to (command["id"] as? String ?: ""),
                                    "ok" to false,
                                    "rev" to 0,
                                    "code" to "unsupported",
                                ),
                            )
                        }
                    })
                }
            },
            snapshot = { lastJson },
        )
        server = created
        return created
    }

    private fun startServer(): Map<String, Any?> {
        val store = prefs() ?: return unsupportedMap()
        store.serverEnabled = true
        val running = server()?.start() ?: false
        if (!running) {
            store.serverEnabled = false
            return serverStatus() + mapOf("error" to "start_failed")
        }
        return serverStatus()
    }

    private fun stopServer(): Map<String, Any?> {
        prefs()?.serverEnabled = false
        server?.stop()
        return serverStatus()
    }

    private fun beginPairing(): Map<String, Any?> {
        val store = prefs() ?: return unsupportedMap()
        store.serverEnabled = true
        val target = server()
        if (target == null || !target.start()) {
            store.serverEnabled = false
            return serverStatus() + mapOf("error" to "start_failed")
        }
        store.newPairingPin()
        target.startPairing()
        return serverStatus()
    }

    private fun cancelPairing(): Map<String, Any?> {
        server?.cancelPairing()
        return serverStatus()
    }

    private fun forgetServer(): Map<String, Any?> {
        val store = prefs() ?: return unsupportedMap()
        server?.stop()
        store.serverEnabled = false
        store.clearPairing()
        store.forgetAll()
        lastJson = null
        return serverStatus()
    }

    private fun serverStatus(): Map<String, Any?> {
        val store = prefs() ?: return unsupportedMap()
        val target = server()
        if (target != null) return target.statusMap()
        return mapOf(
            "supported" to (Build.VERSION.SDK_INT >= 31),
            "enabled" to store.serverEnabled,
            "state" to if (store.serverEnabled) "idle" else "disabled",
            "deviceName" to store.lastWatchName,
            "address" to "",
            "error" to "",
            "pairingCode" to "",
            "pairingUntil" to "",
            "sdk" to Build.VERSION.SDK_INT,
        )
    }

    private fun startClient(address: String, name: String): Map<String, Any?> {
        if (address.isBlank()) return clientStatus() + mapOf("error" to "no_phone")
        return client(address, name)?.start(address, name) ?: unsupportedMap()
    }

    private fun stopClient(): Map<String, Any?> = client?.stop() ?: clientStatus()

    private fun clientStatus(): Map<String, Any?> =
        client?.statusMap() ?: prefs()?.let {
            mapOf(
                "supported" to (Build.VERSION.SDK_INT >= 31),
                "enabled" to it.clientEnabled,
                "state" to if (it.clientEnabled) "idle" else "disabled",
                "deviceName" to it.phoneName,
                "address" to it.phoneAddress,
                "error" to "",
                "pairingCode" to "",
                "sdk" to Build.VERSION.SDK_INT,
                "pinRequired" to false,
            )
        } ?: unsupportedMap()

    private fun forgetPhone(): Map<String, Any?> {
        val store = prefs() ?: return unsupportedMap()
        val target = client ?: client(store.phoneAddress, store.phoneName)
        val status = target?.forget() ?: store.run {
            clientEnabled = false
            watchPsk = null
            phoneAddress = ""
            phoneName = ""
            mapOf(
                "supported" to (Build.VERSION.SDK_INT >= 31),
                "enabled" to false,
                "state" to "disabled",
                "deviceName" to "",
                "address" to "",
                "error" to "",
                "pairingCode" to "",
                "sdk" to Build.VERSION.SDK_INT,
                "pinRequired" to false,
            )
        }
        return status
    }

    private fun client(address: String, name: String): WearGattClient? {
        val current = activity ?: return null
        client?.let { return it }
        val store = WearPrefs(current)
        val created = WearGattClient(
            context = current.applicationContext,
            prefs = store,
            onEvent = { event -> channel?.invokeMethod("clientEvent", event) },
            onState = { state -> channel?.invokeMethod("state", state) },
            onAck = { ack -> channel?.invokeMethod("ack", ack) },
            onPinRequired = { phoneName ->
                channel?.invokeMethod("pinRequired", mapOf("phoneName" to phoneName))
            },
        )
        if (address.isNotBlank()) {
            store.phoneAddress = address
            if (name.isNotBlank()) store.phoneName = name
        }
        client = created
        return created
    }

    private fun bondedDevicesList(): List<Map<String, Any?>> {
        val current = activity ?: return emptyList()
        if (Build.VERSION.SDK_INT >= 31 &&
            current.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return emptyList()
        }
        val manager = current.getSystemService(Context.BLUETOOTH_SERVICE) as? android.bluetooth.BluetoothManager
        val devices = try {
            manager?.adapter?.bondedDevices ?: emptySet()
        } catch (_: Exception) {
            emptySet()
        }
        return devices.map { device ->
            mapOf(
                "address" to device.address,
                "name" to (runCatching { device.name }.getOrNull() ?: ""),
                "type" to device.type,
                "bonded" to (device.bondState == android.bluetooth.BluetoothDevice.BOND_BONDED),
            )
        }
    }

    private fun asMap(value: Any?): Map<String, Any?>? {
        if (value !is Map<*, *>) return null
        return value.entries
            .filter { it.key is String }
            .associate { it.key as String to it.value }
    }

    private fun deniedMap(): Map<String, Any?> =
        mapOf(
            "supported" to (Build.VERSION.SDK_INT >= 31),
            "enabled" to false,
            "state" to "error",
            "deviceName" to "",
            "address" to "",
            "error" to "permission",
            "code" to "permission",
            "pairingCode" to "",
            "sdk" to Build.VERSION.SDK_INT,
        )

    private fun unsupportedMap(): Map<String, Any?> =
        mapOf(
            "supported" to false,
            "enabled" to false,
            "state" to "unsupported",
            "deviceName" to "",
            "address" to "",
            "error" to "unsupported",
            "pairingCode" to "",
            "sdk" to Build.VERSION.SDK_INT,
        )
}
