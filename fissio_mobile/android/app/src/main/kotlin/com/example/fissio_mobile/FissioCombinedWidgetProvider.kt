package com.example.fissio_mobile

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Widget 4: ikili kısayol — solda "Fiş tara" (`fissio://scan`), sağda "Dijital fiş" (`fissio://import-digital`).
 * Renk teması WidgetTheming'ten.
 */
class FissioCombinedWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences) {
        val style = WidgetTheming.read(widgetData)
        appWidgetIds.forEach { id ->
            val views = try {
                RemoteViews(context.packageName, R.layout.widget_combined).apply {
                    WidgetTheming.applyBackground(context, this, R.id.widget_root, style)
                    WidgetTheming.applyButton(context, this, R.id.widget_scan, R.id.widget_scan_icon, R.id.widget_scan_label, style)
                    WidgetTheming.applyButton(context, this, R.id.widget_digital, R.id.widget_digital_icon, R.id.widget_digital_label, style)
                    setOnClickPendingIntent(R.id.widget_root, WidgetTheming.launchIntent(context, null, 20))
                    setOnClickPendingIntent(R.id.widget_scan, WidgetTheming.launchIntent(context, WidgetTheming.SCAN_URI, 21))
                    setOnClickPendingIntent(R.id.widget_digital, WidgetTheming.launchIntent(context, WidgetTheming.IMPORT_URI, 22))
                }
            } catch (e: Exception) {
                RemoteViews(context.packageName, R.layout.widget_combined)
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
