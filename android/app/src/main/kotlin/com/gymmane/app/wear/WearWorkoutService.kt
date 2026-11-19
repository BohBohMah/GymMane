package com.gymmane.app.wear

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import androidx.wear.ongoing.OngoingActivity
import com.gymmane.app.MainActivity
import com.gymmane.app.R

/** Local, user-visible companion session. The phone remains authoritative. */
class WearWorkoutService : Service() {
    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Workout", NotificationManager.IMPORTANCE_LOW),
        )
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(
                Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP,
            ),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_gymmane)
            .setContentTitle("GymMane")
            .setContentText("Workout in progress")
            .setCategory(NotificationCompat.CATEGORY_WORKOUT)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
        if (packageManager.hasSystemFeature(PackageManager.FEATURE_WATCH)) {
            OngoingActivity.Builder(this, ID, notification)
                .setStaticIcon(R.drawable.ic_stat_gymmane)
                .setTouchIntent(open)
                .build()
                .apply(this)
        }
        startForeground(ID, notification.build())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_NOT_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        WearLinkBridge.onWorkoutServiceStopped()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "wear_workout_ongoing"
        private const val ID = 74120

        fun start(context: Context): Boolean = try {
            context.startForegroundService(Intent(context, WearWorkoutService::class.java))
            true
        } catch (_: Exception) {
            false
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, WearWorkoutService::class.java))
        }
    }
}
