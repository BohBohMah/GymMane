package com.gymmane.app.wear

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.gymmane.app.CompanionTiles
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

object WearLinkBridge {
    const val CHANNEL = "gymmane/wearlink"
    private const val REQUEST = 7412
    private const val NOTIFICATION_REQUEST = 7413

    private var activity: Activity? = null
    private var channel: MethodChannel? = null
    private var server: WearGattServer? = null
    private var client: WearGattClient? = null
    private var clientSyncPending = false
    private var lastJson: String? = null
    private var workoutServiceActive = false

    private data class PermissionRequest(
        val result: MethodChannel.Result,
        val requiresAdvertising: Boolean,
        val action: () -> Any?,
    )

    private var permissionRequest: PermissionRequest? = null

    fun attach(activity: Activity, channel: MethodChannel) {
        this.activity?.takeIf { it !== activity }?.let(::detach)
        this.activity = activity
        this.channel = channel
        WearLinkDiagnostics.initialize(activity.applicationContext)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "diagnostic" -> {
                    val message = call.argument<String>("message")
                    if (message != null) WearLinkDiagnostics.log("dart $message")
                    result.success(null)
                }
                "startServer" -> ensure(true, result) { startServer() }
                "stop" -> result.success(stopServer())
                "beginPairing" -> ensure(true, result) { beginPairing() }
                "cancelPairing" -> result.success(cancelPairing())
                "forget" -> result.success(forgetServer())
                "status" -> result.success(serverStatus())
                "wakeServer" -> {
                    if (!isWatch() && prefs()?.serverEnabled == true && missing(true).isEmpty()) {
                        server()?.start()
                    }
                    result.success(serverStatus())
                }
                "update" -> {
                    lastJson = call.argument<String>("json")
                    server?.updateSnapshot(lastJson ?: "")
                    val active = runCatching {
                        isWorkoutOngoing(JSONObject(lastJson ?: "{}").optString("status"))
                    }.getOrDefault(false)
                    if (!isWatch()) updateWorkoutService(activity.applicationContext, active)
                    result.success(null)
                }
                "bondedDevices" -> ensure(false, result) { bondedDevicesList() }
                "startClient" -> {
                    val address = call.argument<String>("address") ?: ""
                    val name = call.argument<String>("name") ?: ""
                    ensure(false, result) { startClient(address, name) }
                }
                "stopClient" -> result.success(stopClient())
                "resumeClient" -> {
                    val store = prefs()
                    val next = if (store?.clientEnabled == true && missing(false).isEmpty()) {
                        client()?.resume()
                    } else null
                    result.success(next ?: clientStatus())
                }
                "clientStatus" -> result.success(clientStatus())
                "submitPin" -> {
                    val pin = call.argument<String>("pin") ?: ""
                    result.success(client?.submitPin(pin) ?: false)
                }
                "forgetPhone" -> result.success(forgetPhone())
                "sendCommand" -> {
                    val raw = call.arguments
                    val command = asMap(raw)
                    if (command != null) {
                        client?.sendCommand(command)
                        result.success(null)
                    } else {
                        result.error("bad-command", "command must be a map", null)
                    }
                }
                "requestState" -> {
                    client?.requestState()
                    result.success(null)
                }
                "setSyncPending" -> {
                    clientSyncPending = call.argument<Boolean>("pending") == true
                    client?.setSyncPending(clientSyncPending)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun detach(activity: Activity) {
        if (this.activity !== activity) return
        val request = permissionRequest
        permissionRequest = null
        request?.result?.success(deniedMap())
        channel?.setMethodCallHandler(null)
        channel = null
        this.activity = null
        if (!workoutServiceActive) closeTransport()
    }

    fun onWorkoutServiceStopped() {
        workoutServiceActive = false
        if (activity == null) closeTransport()
    }

    private fun closeTransport() {
        server?.stop()
        server = null
        lastJson = null
        client?.shutdown()
        client = null
    }

    fun onPermissionResult(owner: Activity, requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode == NOTIFICATION_REQUEST) return true
        if (requestCode != REQUEST) return false
        if (activity !== owner) return true
        val request = permissionRequest ?: return true
        permissionRequest = null
        val granted = grantResults.isNotEmpty() && missing(request.requiresAdvertising).isEmpty()
        request.result.success(if (granted) request.action() else deniedMap())
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
        if (permissionRequest != null) {
            result.success(deniedMap())
            return
        }
        permissionRequest = PermissionRequest(result, advertise, action)
        try {
            current.requestPermissions(missing, REQUEST)
        } catch (_: Exception) {
            permissionRequest = null
            result.success(deniedMap())
        }
    }

    private fun isWorkoutOngoing(status: Any?): Boolean =
        status == "active" || status == "paused" || status == "parked"

    private fun updateWorkoutService(context: Context, active: Boolean) {
        if (active == workoutServiceActive) return
        if (active) {
            requestNotificationPermission()
            workoutServiceActive = WearWorkoutService.start(context)
        } else {
            WearWorkoutService.stop(context)
            workoutServiceActive = false
        }
    }

    private fun requestNotificationPermission() {
        val current = activity ?: return
        if (Build.VERSION.SDK_INT < 33 ||
            current.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        ) return
        runCatching {
            current.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_REQUEST)
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
        val enroll = !store.serverEnabled && store.keyCount() == 0
        store.serverEnabled = true
        val running = server()?.start() ?: false
        if (!running) {
            store.serverEnabled = false
            return serverStatus() + mapOf("error" to "start_failed")
        }
        if (enroll) {
            store.newPairingPin()
            server?.startPairing()
        }
        return serverStatus()
    }

    private fun stopServer(): Map<String, Any?> {
        prefs()?.serverEnabled = false
        server?.stop()
        if (!isWatch() && workoutServiceActive) {
            activity?.applicationContext?.let { WearWorkoutService.stop(it) }
            workoutServiceActive = false
        }
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
        return client()?.start(address, name) ?: unsupportedMap()
    }

    private fun stopClient(): Map<String, Any?> {
        val result = client?.stop() ?: clientStatus()
        activity?.applicationContext?.let { WearWorkoutService.stop(it) }
        workoutServiceActive = false
        return result
    }

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
        if (isWatch()) activity?.let { CompanionTiles.clear(it.applicationContext) }
        activity?.applicationContext?.let { WearWorkoutService.stop(it) }
        workoutServiceActive = false
        val store = prefs() ?: return unsupportedMap()
        val target = client ?: client()
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

    private fun client(): WearGattClient? {
        val current = activity ?: return null
        client?.let { return it }
        val store = WearPrefs(current)
        val appContext = current.applicationContext
        var latestTileState: Map<String, Any?>? = null
        val created = WearGattClient(
            context = appContext,
            prefs = store,
            onEvent = { event ->
                if (event["state"] != "connected") latestTileState = null
                channel?.invokeMethod("clientEvent", event)
            },
            onState = { state ->
                latestTileState = state
                CompanionTiles.save(appContext, state)
                updateWorkoutService(appContext, isWorkoutOngoing(state["status"]))
                channel?.invokeMethod("state", state - "home")
            },
            onHome = { home ->
                latestTileState?.let { CompanionTiles.save(appContext, it + ("home" to home)) }
                channel?.invokeMethod("home", home)
            },
            onAck = { ack -> channel?.invokeMethod("ack", ack) },
            onPinRequired = { phoneName ->
                channel?.invokeMethod("pinRequired", mapOf("phoneName" to phoneName))
            },
        )
        created.setSyncPending(clientSyncPending)
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
