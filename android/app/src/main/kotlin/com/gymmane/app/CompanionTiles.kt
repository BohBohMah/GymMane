package com.gymmane.app

import android.content.ComponentName
import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.wear.protolayout.ActionBuilders
import androidx.wear.protolayout.ColorBuilders.argb
import androidx.wear.protolayout.DimensionBuilders.dp
import androidx.wear.protolayout.DimensionBuilders.expand
import androidx.wear.protolayout.DimensionBuilders.sp
import androidx.wear.protolayout.LayoutElementBuilders
import androidx.wear.protolayout.ModifiersBuilders
import androidx.wear.protolayout.ResourceBuilders
import androidx.wear.protolayout.TimelineBuilders
import androidx.wear.tiles.RequestBuilders
import androidx.wear.tiles.TileBuilders
import androidx.wear.tiles.TileService
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester
import com.google.common.util.concurrent.ListenableFuture
import org.json.JSONObject
import java.time.LocalDate
import java.util.Locale

/** Private, minimal projection of the last authenticated phone snapshot. */
internal object CompanionTiles {
    private const val PREFS = "gymmane_companion_tiles"

    fun save(context: Context, state: Map<String, Any?>) {
        if (BuildConfig.APPLICATION_ID != "com.gymmane.test.wear") return
        val home = state["home"] as? Map<*, *> ?: return
        val today = home["today"] as? Map<*, *>
        val previous = workout(context)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val oldLanguage = prefs.getString("language", null)
        val language = (home["language"] as? String)?.let { if (it == "it") "it" else "en" } ?: oldLanguage
        if (language != oldLanguage) prefs.edit().putString("language", language).apply()
        val active = state["status"] in listOf("active", "paused", "parked")
        val workoutSnapshot = JSONObject()
            .put("day", home["day"])
            .put("language", language)
            .put("active", active)
            .put("title", if (active) state["name"] else today?.get("name"))
            .put("done", home["weekDone"])
            .put("goal", home["weekGoal"])
            .put("streak", home["streak"])
        val water = JSONObject()
            .put("day", home["day"])
            .put("language", language)
            .put("enabled", home["nutrition"])
            .put("ml", home["water"])
            .put("goal", home["waterGoal"])
        store(context, "workout", workoutSnapshot.toString(), CompanionWorkoutTile::class.java)
        store(context, "water", water.toString(), CompanionWaterTile::class.java)
        val current = workout(context)
        if (previous?.done != current?.done || previous?.goal != current?.goal || language != oldLanguage) {
            refreshComplication(context)
        }
    }

    fun clear(context: Context) {
        store(context, "workout", "", CompanionWorkoutTile::class.java)
        store(context, "water", "", CompanionWaterTile::class.java)
        refreshComplication(context)
    }

    fun workout(context: Context): WearData? {
        val data = read(context, "workout")
        val goal = data.optInt("goal")
        if (goal <= 0 || !data.has("done")) return null
        return WearData(
            done = data.optInt("done").coerceAtLeast(0),
            goal = goal,
            streak = data.optInt("streak").coerceAtLeast(0),
            next = data.optString("title"),
            live = data.optBoolean("active"),
        )
    }

    fun strings(context: Context): Resources {
        val cached = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("language", null)
        val language = cached ?: context.resources.configuration.locales[0].language
        val locale = if (language == "it") Locale.ITALIAN else Locale.ENGLISH
        val configuration = Configuration(context.resources.configuration).apply { setLocale(locale) }
        return context.createConfigurationContext(configuration).resources
    }

    private fun refreshComplication(context: Context) {
        runCatching {
            ComplicationDataSourceUpdateRequester
                .create(context, ComponentName(context, GymComplicationService::class.java))
                .requestUpdateAll()
        }
    }

    fun read(context: Context, key: String): JSONObject {
        val value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(key, null)
        val data = value?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return JSONObject()
        return if (data.optString("day") == LocalDate.now().toString()) data else JSONObject()
    }

    private fun store(context: Context, key: String, value: String, tile: Class<out TileService>) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getString(key, "") == value) return
        prefs.edit().putString(key, value).apply()
        runCatching { TileService.getUpdater(context).requestUpdate(tile) }
    }
}

class CompanionWorkoutTile : GymTileService() {
    override val openRoute = "wear/workout"
    override val freshnessMillis = 30 * 60 * 1000L
    override fun readData() = CompanionTiles.workout(this)
    override fun actionLabel(live: Boolean) = if (live) R.string.tile_continue else R.string.tile_open
    override fun tileResources() = CompanionTiles.strings(this)
}

class CompanionWaterTile : TileService() {
    override fun onTileRequest(requestParams: RequestBuilders.TileRequest): ListenableFuture<TileBuilders.Tile> =
        CallbackToFutureAdapter.getFuture { completer ->
            completer.set(TileBuilders.Tile.Builder()
                .setResourcesVersion("1")
                .setFreshnessIntervalMillis(30 * 60 * 1000L)
                .setTileTimeline(TimelineBuilders.Timeline.fromLayoutElement(layout()))
                .build())
            "gymmane-companion-water"
        }

    override fun onTileResourcesRequest(
        requestParams: RequestBuilders.ResourcesRequest,
    ): ListenableFuture<ResourceBuilders.Resources> = CallbackToFutureAdapter.getFuture { completer ->
        completer.set(ResourceBuilders.Resources.Builder().setVersion("1").build())
        "gymmane-companion-resources"
    }

    private fun layout(): LayoutElementBuilders.LayoutElement {
        val data = CompanionTiles.read(this, "water")
        val localized = CompanionTiles.strings(this)
        val label = localized.getString(R.string.tile_water_title)
        val detail = if (data.optBoolean("enabled")) {
            "${data.optInt("ml")} / ${data.optInt("goal")} ml"
        } else ""
        val action = localized.getString(R.string.tile_open)
        val column = LayoutElementBuilders.Column.Builder()
            .setWidth(dp(138f))
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
            .addContent(text(label, 14f, 0xFFD9A184.toInt()))
        if (detail.isNotBlank()) column.addContent(text(detail, 16f, 0xFFFFFFFF.toInt()))
        column.addContent(LayoutElementBuilders.Spacer.Builder().setHeight(dp(12f)).build())
        column.addContent(
            LayoutElementBuilders.Box.Builder()
                .setWidth(dp(120f))
                .setHeight(dp(48f))
                .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
                .setVerticalAlignment(LayoutElementBuilders.VERTICAL_ALIGN_CENTER)
                .setModifiers(
                    ModifiersBuilders.Modifiers.Builder()
                        .setBackground(ModifiersBuilders.Background.Builder()
                            .setColor(argb(0xFFD9A184.toInt()))
                            .setCorner(ModifiersBuilders.Corner.Builder().setRadius(dp(24f)).build())
                            .build())
                        .setClickable(ModifiersBuilders.Clickable.Builder()
                            .setId("water")
                            .setOnClick(ActionBuilders.LaunchAction.Builder()
                                .setAndroidActivity(ActionBuilders.AndroidActivity.Builder()
                                    .setPackageName(packageName)
                                    .setClassName(MainActivity::class.java.name)
                                    .addKeyToExtraMapping(
                                        "gymmane_open",
                                        ActionBuilders.AndroidStringExtra.Builder().setValue("wear/nutrition").build(),
                                    )
                                    .build())
                                .build())
                            .build())
                        .build())
                .addContent(text(action, 15f, 0xFF19110D.toInt()))
                .build()
        )
        return LayoutElementBuilders.Box.Builder()
            .setWidth(expand())
            .setHeight(expand())
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
            .setVerticalAlignment(LayoutElementBuilders.VERTICAL_ALIGN_CENTER)
            .addContent(column.build())
            .build()
    }

    private fun text(value: String, size: Float, color: Int) = LayoutElementBuilders.Text.Builder()
        .setText(value)
        .setMaxLines(2)
        .setMultilineAlignment(LayoutElementBuilders.TEXT_ALIGN_CENTER)
        .setOverflow(LayoutElementBuilders.TEXT_OVERFLOW_ELLIPSIZE_END)
        .setFontStyle(LayoutElementBuilders.FontStyle.Builder().setSize(sp(size)).setColor(argb(color)).build())
        .build()
}
