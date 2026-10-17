package dev.resassance.linkindrop

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.net.wifi.WifiManager

class ConnectionService : Service() {
    companion object {
        var running = false
            private set
        private fun notification(context: Context, text: String): Notification {
            val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val clipboard = PendingIntent.getActivity(context, 1, Intent(context, MainActivity::class.java).putExtra("clipboard", true), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, "connection") else Notification.Builder(context)
            return builder.setContentTitle("LinkInDrop").setContentText(text).setSmallIcon(R.drawable.tile_icon)
                .setContentIntent(open).setOngoing(true).addAction(Notification.Action.Builder(null, NativeStrings.text(context, "Отправить буфер"), clipboard).build()).build()
        }
        fun update(context: Context, text: String) {
            if (running) context.getSystemService(NotificationManager::class.java).notify(731, notification(context, text))
        }
    }
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null
    private val handler = Handler(Looper.getMainLooper())
    private val renew = object : Runnable {
        override fun run() {
            if (!running) return
            wake?.let { if (it.isHeld) it.release(); it.acquire(10 * 60 * 1000L) }
            handler.postDelayed(this, 5 * 60 * 1000L)
        }
    }
    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("connection", NativeStrings.text(this, "Подключение устройств"), NotificationManager.IMPORTANCE_LOW))
        startForeground(731, notification(this, NativeStrings.text(this, "Служба передачи файлов работает")))
        running = true
        wake = (getSystemService(Context.POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "linkindrop:connection").apply { setReferenceCounted(false) }
        wifi = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "linkindrop:connection").apply { setReferenceCounted(false); acquire() }
        handler.post(renew)
        (application as BridgeApplication).ensureEngine()
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!getSharedPreferences("connection", MODE_PRIVATE).getBoolean("enabled", true)) { stopSelf(); return START_NOT_STICKY }
        return START_STICKY
    }
    override fun onDestroy() {
        running = false
        handler.removeCallbacks(renew)
        wake?.let { if (it.isHeld) it.release() }
        wifi?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
