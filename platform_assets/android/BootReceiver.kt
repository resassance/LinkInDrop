package dev.resassance.nearbridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED)) return
        val preferences = context.getSharedPreferences("connection", Context.MODE_PRIVATE)
        if (!preferences.getBoolean("enabled", false) || !preferences.getBoolean("boot", false)) return
        try {
            val service = Intent(context, ConnectionService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(service) else context.startService(service)
        } catch (_: Exception) {}
    }
}
