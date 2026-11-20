package com.example.fissio_mobile

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.view.View
import java.util.Calendar
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Ana ekran widget'ı (1/4): aktif profilin "Bu ayki toplam harcaması" + "Fiş tara" ve "Dijital fiş" kısayolları.
 * Renk teması (Sistem/Açık/Koyu/Marka) WidgetTheming'ten; diğer 3 widget (FissioScan/Digital/CombinedWidgetProvider)
 * yalnızca kısayol içerir.
 * Veri Dart tarafından `home_widget` ile yazılır (anahtarlar lib/services/widget_sync.dart -> WidgetKeys):
 * fissio_signed_in, fissio_profile, fissio_month_total, fissio_month_label, fissio_month_key,
 * fissio_widget_theme, fissio_widget_accent.
 * Oturum yoksa (çıkış / hesap silme) önceki kullanıcının tutarı gösterilmez.
 */
class FissioWidgetProvider : HomeWidgetProvider() {
    /**
     * Gün/saat/saat dilimi değişince (gece yarısı, ay dönümü) widget'ı yeniden çizer: ay anahtarı (`fissio_month_key`)
     * artık geçerli aydan farklıysa eski ayın tutarı yerine "yeni ay" ipucu gösterilir (tutarı yalnızca uygulama hesaplar).
     */
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        when (intent.action) {
            Intent.ACTION_DATE_CHANGED, Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED -> {
                val manager = AppWidgetManager.getInstance(context)
                val ids = manager.getAppWidgetIds(ComponentName(context, FissioWidgetProvider::class.java))
                if (ids.isNotEmpty()) {
                    onUpdate(context, manager, ids, HomeWidgetPlugin.getData(context))
                }
            }
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            // Hiçbir koşulda çökmesin: veri okunamazsa bile "0,00 ₺" ile düzgün çizilir.
            val views = try {
                buildViews(context, widgetData)
            } catch (e: Exception) {
                fallbackViews(context)
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    private fun buildViews(context: Context, widgetData: SharedPreferences): RemoteViews {
        // Uygulama henüz hiç veri yazmadıysa (widget yeni eklendi) anahtar yoktur: "0,00 ₺" gösterilir.
        val hasData = widgetData.contains("fissio_signed_in")
        val signedIn = widgetData.getBoolean("fissio_signed_in", false)
        val total = widgetData.getString("fissio_month_total", null).orEmpty()
        val profile = widgetData.getString("fissio_profile", null).orEmpty()
        val month = widgetData.getString("fissio_month_label", null).orEmpty()
        // Uygulama son kez başka bir ayda yazdıysa (ay dönümünden sonra uygulama açılmadı) eski tutar gösterilmez.
        val monthKey = widgetData.getString("fissio_month_key", null).orEmpty()
        val stale = monthKey.isNotEmpty() && monthKey != currentMonthKey()
        val style = WidgetTheming.read(widgetData)

        return RemoteViews(context.packageName, R.layout.fissio_widget).apply {
            WidgetTheming.applyBackground(this, R.id.widget_root, style)
            WidgetTheming.applyText(context, this, R.id.widget_title, style, mute = true)
            WidgetTheming.applyText(context, this, R.id.widget_total, style, mute = false)
            WidgetTheming.applyText(context, this, R.id.widget_subtitle, style, mute = true)
            WidgetTheming.applyButton(this, R.id.widget_scan, R.id.widget_scan_icon, R.id.widget_scan_label, style)
            WidgetTheming.applyButton(this, R.id.widget_digital, R.id.widget_digital_icon, R.id.widget_digital_label, style)
            when {
                !hasData -> {
                    setTextViewText(R.id.widget_total, context.getString(R.string.widget_empty_total))
                    setTextViewText(R.id.widget_subtitle, context.getString(R.string.widget_empty_hint))
                    setViewVisibility(R.id.widget_subtitle, View.VISIBLE)
                }
                signedIn && stale -> {
                    setTextViewText(R.id.widget_total, context.getString(R.string.widget_empty_total))
                    setTextViewText(R.id.widget_subtitle, context.getString(R.string.widget_new_month_hint))
                    setViewVisibility(R.id.widget_subtitle, View.VISIBLE)
                }
                signedIn -> {
                    setTextViewText(
                        R.id.widget_total,
                        total.ifEmpty { context.getString(R.string.widget_empty_total) },
                    )
                    setTextViewText(
                        R.id.widget_subtitle,
                        listOf(profile, month).filter { it.isNotEmpty() }.joinToString(" · "),
                    )
                    setViewVisibility(R.id.widget_subtitle, View.VISIBLE)
                }
                else -> {
                    // Çıkış / hesap silme: önceki kullanıcının tutarı gösterilmez.
                    setTextViewText(R.id.widget_total, context.getString(R.string.widget_signed_out))
                    setViewVisibility(R.id.widget_subtitle, View.GONE)
                }
            }
            // Widget'a dokunmak uygulamayı açar; "Fiş tara" doğrudan tarama ekranını (fissio://scan), "Dijital fiş"
            // doğrudan PDF seçiciyi (fissio://import-digital) açar. Oturum yoksa uygulama giriş ekranını açar, giriş
            // sonrası ilgili eylem bekleyen istek olarak çalışır.
            setOnClickPendingIntent(R.id.widget_root, WidgetTheming.launchIntent(context, null, 0))
            setOnClickPendingIntent(R.id.widget_scan, WidgetTheming.launchIntent(context, WidgetTheming.SCAN_URI, 1))
            setOnClickPendingIntent(R.id.widget_digital, WidgetTheming.launchIntent(context, WidgetTheming.IMPORT_URI, 2))
        }
    }

    /** Dart `WidgetPayload.monthKey` ile aynı biçim: yıl-ay (ay 1-12), örn. 2026-5. */
    private fun currentMonthKey(): String {
        val c = Calendar.getInstance()
        return "${c.get(Calendar.YEAR)}-${c.get(Calendar.MONTH) + 1}"
    }

    private fun fallbackViews(context: Context): RemoteViews =
        RemoteViews(context.packageName, R.layout.fissio_widget).apply {
            setTextViewText(R.id.widget_total, context.getString(R.string.widget_empty_total))
            setViewVisibility(R.id.widget_subtitle, View.GONE)
        }
}
