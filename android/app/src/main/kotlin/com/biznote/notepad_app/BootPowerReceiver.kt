package com.biznote.notepad_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import id.flutter.flutter_background_service.BackgroundService

class BootPowerReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != Intent.ACTION_POWER_CONNECTED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) return
        try {
            val serviceIntent = Intent(context, BackgroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } catch (e: Exception) {
            // Ignore – the plugin's own BootReceiver will also retry.
        }
    }
}
