package dev.resassance.nearbridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

class ConnectionService : Service() {
    companion object {
        var running = false
            private set
        private fun notification(context: Context, text: String): Notification {
            val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val clipboard = PendingIntent.getActivity(context, 1, Intent(context, MainActivity::class.java).putExtra("clipboard", true), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, "connection") else Notification.Builder(context)
            return builder.setContentTitle("Nearbridge").setContentText(text).setSmallIcon(R.drawable.tile_icon)
                .setContentIntent(open).setOngoing(true).addAction(Notification.Action.Builder(null, "Отправить буфер", clipboard).build()).build()
        }
        fun update(context: Context, text: String) {
            if (running) context.getSystemService(NotificationManager::class.java).notify(731, notification(context, text))
        }
    }
    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("connection", "Подключение устройств", NotificationManager.IMPORTANCE_LOW))
        startForeground(731, notification(this, "Служба передачи файлов работает"))
        running = true
        (application as BridgeApplication).ensureEngine()
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!getSharedPreferences("connection", MODE_PRIVATE).getBoolean("enabled", true)) { stopSelf(); return START_NOT_STICKY }
        return START_STICKY
    }
    override fun onDestroy() { running = false; super.onDestroy() }
    override fun onBind(intent: Intent?): IBinder? = null
}
