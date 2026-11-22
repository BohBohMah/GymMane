package com.gymmane.app

import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import androidx.wear.watchface.complications.data.ComplicationData
import androidx.wear.watchface.complications.data.ComplicationType
import androidx.wear.watchface.complications.data.MonochromaticImage
import androidx.wear.watchface.complications.data.NoDataComplicationData
import androidx.wear.watchface.complications.data.PlainComplicationText
import androidx.wear.watchface.complications.data.RangedValueComplicationData
import androidx.wear.watchface.complications.data.ShortTextComplicationData
import androidx.wear.watchface.complications.datasource.ComplicationRequest
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceService

class GymComplicationService : ComplicationDataSourceService() {
    private val companion get() = BuildConfig.APPLICATION_ID == "com.gymmane.test.wear"
    override fun getPreviewData(type: ComplicationType): ComplicationData? = build(type, WearData(3, 4, 0, "", false))

    override fun onComplicationRequest(request: ComplicationRequest, listener: ComplicationRequestListener) {
        val data = if (companion) CompanionTiles.workout(this) else WearSurfaces.read(this)
        listener.onComplicationData(if (data != null) build(request.complicationType, data) else NoDataComplicationData())
    }

    private fun build(type: ComplicationType, d: WearData): ComplicationData? {
        val text = PlainComplicationText.Builder("${d.done}/${d.goal}").build()
        val localized = if (companion) CompanionTiles.strings(this) else resources
        val description = PlainComplicationText.Builder(localized.getString(R.string.tile_week)).build()
        val image = MonochromaticImage.Builder(Icon.createWithResource(this, R.drawable.ic_complication)).build()
        val tap = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .setAction("com.gymmane.app.wear.OPEN_WEEKLY_PROGRESS")
                .putExtra("gymmane_open", if (companion) "wear/workout" else "play"),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return when (type) {
            ComplicationType.RANGED_VALUE -> RangedValueComplicationData.Builder(
                d.done.toFloat().coerceAtMost(d.goal.toFloat()), 0f, d.goal.toFloat(), description
            ).setText(text).setMonochromaticImage(image).setTapAction(tap).build()

            ComplicationType.SHORT_TEXT -> ShortTextComplicationData.Builder(text, description)
                .setMonochromaticImage(image).setTapAction(tap).build()

            else -> NoDataComplicationData()
        }
    }
}
