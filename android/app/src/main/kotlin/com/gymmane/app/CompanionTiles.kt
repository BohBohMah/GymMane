package com.gymmane.app

import android.content.Context
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
import com.google.common.util.concurrent.ListenableFuture
import org.json.JSONObject
import java.time.LocalDate

/** Private, minimal projection of the last authenticated phone snapshot. */
internal object CompanionTiles {
    private const val PREFS = "gymmane_companion_tiles"

    fun save(context: Context, state: Map<String, Any?>) {
        if (BuildConfig.APPLICATION_ID != "com.gymmane.test.wear") return
        val home = state["home"] as? Map<*, *> ?: return
        val today = home["today"] as? Map<*, *>
        val active = state["status"] in listOf("active", "paused", "parked")
        val workout = JSONObject()
            .put("day", home["day"])
            .put("active", active)
            .put("title", if (active) state["name"] else today?.get("name"))
            .put("done", home["weekDone"])
            .put("goal", home["weekGoal"])
        val water = JSONObject()
            .put("day", home["day"])
            .put("enabled", home["nutrition"])
            .put("ml", home["water"])
            .put("goal", home["waterGoal"])
        store(context, "workout", workout.toString(), CompanionWorkoutTile::class.java)
        store(context, "water", water.toString(), CompanionWaterTile::class.java)
    }

    fun clear(context: Context) {
        store(context, "workout", "", CompanionWorkoutTile::class.java)
        store(context, "water", "", CompanionWaterTile::class.java)
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

class CompanionWorkoutTile : CompanionTile("workout", "wear/workout")
class CompanionWaterTile : CompanionTile("water", "wear/nutrition")

abstract class CompanionTile(private val key: String, private val route: String) : TileService() {
    override fun onTileRequest(requestParams: RequestBuilders.TileRequest): ListenableFuture<TileBuilders.Tile> =
        CallbackToFutureAdapter.getFuture { completer ->
            completer.set(TileBuilders.Tile.Builder()
                .setResourcesVersion("1")
                .setFreshnessIntervalMillis(30 * 60 * 1000L)
                .setTileTimeline(TimelineBuilders.Timeline.fromLayoutElement(layout()))
                .build())
            "gymmane-companion-$key"
        }

    override fun onTileResourcesRequest(
        requestParams: RequestBuilders.ResourcesRequest,
    ): ListenableFuture<ResourceBuilders.Resources> = CallbackToFutureAdapter.getFuture { completer ->
        completer.set(ResourceBuilders.Resources.Builder().setVersion("1").build())
        "gymmane-companion-resources"
    }

    private fun layout(): LayoutElementBuilders.LayoutElement {
        val data = CompanionTiles.read(this, key)
        val water = key == "water"
        val italian = resources.configuration.locales[0].language == "it"
        val label = if (water) {
            if (italian) "Acqua" else "Water"
        } else {
            if (italian) "Allenamento" else "Workout"
        }
        val detail = if (water && data.optBoolean("enabled")) {
            "${data.optInt("ml")} / ${data.optInt("goal")} ml"
        } else if (!water && data.has("done")) {
            "${data.optInt("done")} / ${data.optInt("goal")} ${if (italian) "giorni" else "days"}"
        } else ""
        val action = if (!water && data.optBoolean("active")) {
            if (italian) "Riprendi" else "Resume"
        } else if (italian) "Apri" else "Open"
        val column = LayoutElementBuilders.Column.Builder()
            .setWidth(dp(138f))
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
            .addContent(text(label, 14f, 0xFFD9A184.toInt()))
        val title = data.optString("title")
        if (title.isNotBlank()) column.addContent(text(title, 17f, 0xFFFFFFFF.toInt()))
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
                            .setId(key)
                            .setOnClick(ActionBuilders.LaunchAction.Builder()
                                .setAndroidActivity(ActionBuilders.AndroidActivity.Builder()
                                    .setPackageName(packageName)
                                    .setClassName(MainActivity::class.java.name)
                                    .addKeyToExtraMapping(
                                        "gymmane_open",
                                        ActionBuilders.AndroidStringExtra.Builder().setValue(route).build(),
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
