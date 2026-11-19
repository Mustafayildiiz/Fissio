package com.example.fissio_mobile

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.ComponentName
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import java.util.Calendar
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Ana ekran widget'ı: aktif profilin "Bu ayki toplam harcaması" ve hızlı tarama kısayolu.
 * Veri Dart tarafından `home_widget` ile yazılır (anahtarlar lib/services/widget_sync.dart -> WidgetKeys):
 * fissio_signed_in, fissio_profile, fissio_month_total, fissio_month_label, fissio_month_key.
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

        return RemoteViews(context.packageName, R.layout.fissio_widget).apply {
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
            // Widget'a dokunmak uygulamayı açar; "Fiş tara" doğrudan tarama ekranını (fissio://scan). Oturum
            // yoksa uygulama giriş ekranını açar, giriş sonrası tarama ekranı bekleyen istek olarak açılır.
            setOnClickPendingIntent(R.id.widget_root, launchIntent(context, null, 0))
            setOnClickPendingIntent(R.id.widget_scan, launchIntent(context, Uri.parse("fissio://scan"), 1))
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
