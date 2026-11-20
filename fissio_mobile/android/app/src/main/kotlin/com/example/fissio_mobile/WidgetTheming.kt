package com.example.fissio_mobile

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.ColorStateList
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import android.appwidget.AppWidgetManager

/**
 * Ana ekran widget'larının (toplam + 3 kısayol) ortak renk teması. Tercih Dart tarafından `home_widget` ile yazılır
 * (anahtarlar lib/services/widget_sync.dart -> WidgetKeys): `fissio_widget_theme` (system|light|dark|brand) ve
 * `fissio_widget_accent` (marka rengi, `#AARRGGBB`).
 *
 *  - system: layout'taki `@color/widget_*` renkleri (values / values-night) aynen; telefonun açık/koyu teması izlenir.
 *  - light / dark: sabit açık / koyu zemin ve yazı rengi.
 *  - brand: zemin = marka rengi (API 31+ `setBackgroundTintList`; daha eskide sabit kırmızı yedek), yazı beyaz, düğme
 *    beyaz zeminde marka renkli.
 */
object WidgetTheming {
    enum class Theme { SYSTEM, LIGHT, DARK, BRAND }

    class Style(val theme: Theme, val accent: Int)

    private const val DEFAULT_ACCENT = "#FFEC3013"

    fun read(prefs: SharedPreferences): Style {
        val theme = when (prefs.getString("fissio_widget_theme", null)) {
            "light" -> Theme.LIGHT
            "dark" -> Theme.DARK
            "brand" -> Theme.BRAND
            else -> Theme.SYSTEM
        }
        val accent = try {
            Color.parseColor(prefs.getString("fissio_widget_accent", null) ?: DEFAULT_ACCENT)
        } catch (e: Exception) {
            Color.parseColor(DEFAULT_ACCENT)
        }
        return Style(theme, accent)
    }

    /** Widget zemini (köşeleri yuvarlak). */
    fun applyBackground(views: RemoteViews, rootId: Int, style: Style) {
        when (style.theme) {
            Theme.SYSTEM -> views.setInt(rootId, "setBackgroundResource", R.drawable.widget_bg)
            Theme.LIGHT -> views.setInt(rootId, "setBackgroundResource", R.drawable.widget_bg_light)
            Theme.DARK -> views.setInt(rootId, "setBackgroundResource", R.drawable.widget_bg_dark)
            Theme.BRAND -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    views.setInt(rootId, "setBackgroundResource", R.drawable.widget_bg_tint)
                    views.setColorStateList(rootId, "setBackgroundTintList", ColorStateList.valueOf(style.accent))
                } else {
                    views.setInt(rootId, "setBackgroundResource", R.drawable.widget_bg_brand)
                }
            }
        }
    }

    /** Başlık/tutar (mute=false) ve alt başlık (mute=true) yazı rengi. system temada layout renkleri korunur. */
    fun applyText(context: Context, views: RemoteViews, textId: Int, style: Style, mute: Boolean) {
        val res = when (style.theme) {
            Theme.SYSTEM -> return
            Theme.LIGHT -> if (mute) R.color.widget_light_mute else R.color.widget_light_ink
            Theme.DARK -> if (mute) R.color.widget_dark_mute else R.color.widget_dark_ink
            Theme.BRAND -> if (mute) R.color.widget_brand_mute else R.color.widget_brand_ink
        }
        views.setTextColor(textId, context.getColor(res))
    }

    /** Eylem düğmesi: system/light/dark'ta marka renkli (layout varsayılanı), brand'de beyaz zeminde marka renkli yazı. */
    fun applyButton(views: RemoteViews, buttonId: Int, iconId: Int, labelId: Int, style: Style) {
        if (style.theme != Theme.BRAND) return
        views.setInt(buttonId, "setBackgroundResource", R.drawable.widget_btn_inverse)
        views.setTextColor(labelId, style.accent)
        views.setInt(iconId, "setColorFilter", style.accent)
    }

    /**
     * Uygulamayı açan PendingIntent. Başlatıcı ikonu renge göre değiştirildiği için (MainActivity ya da bir
     * activity-alias etkin olabilir) bileşen adı sabitlenmez; etkin başlatıcı girişi `getLaunchIntentForPackage` ile
     * bulunur. home_widget'ın Dart tarafı (`initiallyLaunchedFromHomeWidget` / `widgetClicked`) bu eylem + adresi okur.
     * Adres: `fissio://scan` (kamera), `fissio://import-digital` (dijital fiş / PDF), null = yalnızca uygulamayı aç.
     */
    fun launchIntent(context: Context, uri: Uri?, requestCode: Int): PendingIntent {
        val intent = (context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)).apply {
            action = HomeWidgetLaunchIntent.HOME_WIDGET_LAUNCH_ACTION
            data = uri
            // Uygulama zaten açıksa (arka planda) yeni görev/ikinci örnek yerine mevcut MainActivity'ye onNewIntent ile
            // gelsin; böylece sıcak açılışta Flutter yeniden başlamaz ve adres doğrudan ilgili eyleme gider.
            flags = flags or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    val SCAN_URI: Uri = Uri.parse("fissio://scan")
    val IMPORT_URI: Uri = Uri.parse("fissio://import-digital")

    /** Verilen sağlayıcının tüm widget örneklerini yeniden çizer (tema/saat dilimi değişimi). */
    fun refresh(context: Context, provider: Class<*>, update: (AppWidgetManager, IntArray) -> Unit) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(ComponentName(context, provider))
        if (ids.isNotEmpty()) update(manager, ids)
    }
}
