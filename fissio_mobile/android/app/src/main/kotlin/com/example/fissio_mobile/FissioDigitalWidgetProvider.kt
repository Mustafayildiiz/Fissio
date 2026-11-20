package com.example.fissio_mobile

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Widget 3: yalnızca "Dijital fiş ekle" kısayolu. Dokununca uygulama doğrudan PDF/e-fatura seçiciyi açar
 * (`fissio://import-digital`). Renk teması WidgetTheming'ten.
 */
class FissioDigitalWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences) {
        val style = WidgetTheming.read(widgetData)
        appWidgetIds.forEach { id ->
            val views = try {
                RemoteViews(context.packageName, R.layout.widget_digital).apply {
                    WidgetTheming.applyBackground(this, R.id.widget_root, style)
                    WidgetTheming.applyButton(this, R.id.widget_action, R.id.widget_action_icon, R.id.widget_action_label, style)
                    val open = WidgetTheming.launchIntent(context, WidgetTheming.IMPORT_URI, 12)
                    setOnClickPendingIntent(R.id.widget_root, open)
                    setOnClickPendingIntent(R.id.widget_action, open)
                }
            } catch (e: Exception) {
                RemoteViews(context.packageName, R.layout.widget_digital)
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
