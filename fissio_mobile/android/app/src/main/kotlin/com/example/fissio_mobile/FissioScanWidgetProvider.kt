package com.example.fissio_mobile

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Widget 2: yalnızca "Fiş tara" kısayolu. Dokununca uygulama ana sayfada durmadan doğrudan kamerayı açar
 * (`fissio://scan`). Renk teması WidgetTheming'ten (tercih: Tercihler > Widget renk teması).
 */
class FissioScanWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences) {
        val style = WidgetTheming.read(widgetData)
        appWidgetIds.forEach { id ->
            // Hiçbir koşulda çökmesin: tema uygulanamazsa varsayılan görünümle çizilir.
            val views = try {
                RemoteViews(context.packageName, R.layout.widget_scan).apply {
                    WidgetTheming.applyBackground(this, R.id.widget_root, style)
                    WidgetTheming.applyButton(this, R.id.widget_action, R.id.widget_action_icon, R.id.widget_action_label, style)
                    val open = WidgetTheming.launchIntent(context, WidgetTheming.SCAN_URI, 11)
                    setOnClickPendingIntent(R.id.widget_root, open)
                    setOnClickPendingIntent(R.id.widget_action, open)
                }
            } catch (e: Exception) {
                RemoteViews(context.packageName, R.layout.widget_scan)
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
