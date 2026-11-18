package com.example.fissio_mobile

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Ana ekran widget'ı: aktif profilin "Bu ayki toplam harcaması" ve hızlı tarama kısayolu.
 * Veri Dart tarafından `home_widget` ile yazılır (anahtarlar lib/services/widget_sync.dart -> WidgetKeys):
 * fissio_signed_in, fissio_profile, fissio_month_total, fissio_month_label.
 * Oturum yoksa (çıkış / hesap silme) önceki kullanıcının tutarı gösterilmez.
 */
class FissioWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val signedIn = widgetData.getBoolean("fissio_signed_in", false)
        val total = widgetData.getString("fissio_month_total", null).orEmpty()
        val profile = widgetData.getString("fissio_profile", null).orEmpty()
        val month = widgetData.getString("fissio_month_label", null).orEmpty()

        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(context.packageName, R.layout.fissio_widget).apply {
                if (signedIn && total.isNotEmpty()) {
                    setTextViewText(R.id.widget_total, total)
                    setTextViewText(
                        R.id.widget_subtitle,
                        listOf(profile, month).filter { it.isNotEmpty() }.joinToString(" · "),
                    )
                    setViewVisibility(R.id.widget_subtitle, View.VISIBLE)
                } else {
                    setTextViewText(R.id.widget_total, context.getString(R.string.widget_signed_out))
                    setViewVisibility(R.id.widget_subtitle, View.GONE)
                }

                // Widget'a dokunmak uygulamayı açar; "Hızlı tara" doğrudan tarama ekranını (fissio://scan).
                setOnClickPendingIntent(R.id.widget_root, launchIntent(context, null, 0))
                setOnClickPendingIntent(R.id.widget_scan, launchIntent(context, Uri.parse("fissio://scan"), 1))
                // Oturum yokken tarama kısayolu gizlenir (giriş yapılmadan tarama açılamaz).
                setViewVisibility(R.id.widget_scan, if (signedIn) View.VISIBLE else View.GONE)
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    /**
     * Uygulamayı açan PendingIntent. Başlatıcı ikonu renge göre değiştirildiği için (MainActivity ya da bir
     * activity-alias etkin olabilir) bileşen adı sabitlenmez; etkin başlatıcı girişi `getLaunchIntentForPackage` ile
     * bulunur. home_widget'ın Dart tarafı (`initiallyLaunchedFromHomeWidget` / `widgetClicked`) bu eylem + adresi okur.
     */
    private fun launchIntent(context: Context, uri: Uri?, requestCode: Int): PendingIntent {
        val intent = (context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)).apply {
            action = HomeWidgetLaunchIntent.HOME_WIDGET_LAUNCH_ACTION
            data = uri
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
