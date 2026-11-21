package com.example.fissio_mobile

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.Configuration
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
 *  - brand: marka rengine göre AÇIK ve KOYU palet (Dart yazar: `fissio_widget_brand_day` / `fissio_widget_brand_night`,
 *    `#bg|#ink|#mute|#btnBg|#btnFg`). Açık palet: zemin = marka rengi; koyu palet: koyu yüzey + marka renkli düğme.
 *    Gün/gece API 31+'da ana ekran (host) tarafından ÇİZİM anında çözülür (`setColorInt` / `setColorStateList` gün/gece
 *    çifti): uygulama kapalıyken telefon temayı değiştirse bile widget doğru renge geçer. API 31 altında palet bu
 *    çizimde `uiMode`'a göre seçilir (bir sonraki güncellemede yenilenir; zemin köşesi kare olur: eski sürümlerde
 *    RemoteViews tint desteği yok).
 */
object WidgetTheming {
    enum class Theme { SYSTEM, LIGHT, DARK, BRAND }

    /** Marka paleti: zemin, yazı, soluk yazı, düğme zemini, düğme yazı/ikon rengi. */
    class Palette(val bg: Int, val ink: Int, val mute: Int, val btnBg: Int, val btnFg: Int)

    class Style(val theme: Theme, val accent: Int, val day: Palette, val night: Palette) {
        /** API 31 altında: bu çizimde geçerli palet (telefonun gece modu). */
        fun current(context: Context): Palette {
            val night = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES
            return if (night) this.night else day
        }
    }

    private const val DEFAULT_ACCENT = "#FFEC3013"

    /** `#bg|#ink|#mute|#btnBg|#btnFg`; eksik/bozuksa null. */
    private fun parsePalette(raw: String?): Palette? {
        if (raw == null) return null
        return try {
            val p = raw.split("|").map { Color.parseColor(it.trim()) }
            if (p.size == 5) Palette(p[0], p[1], p[2], p[3], p[4]) else null
        } catch (e: Exception) {
            null
        }
    }

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
        // Dart paleti yazmadıysa (eski sürüm verisi) marka rengi + varsayılan koyu yüzeyle türetilir.
        val day = parsePalette(prefs.getString("fissio_widget_brand_day", null))
            ?: Palette(accent, Color.WHITE, Color.parseColor("#CCFFFFFF"), Color.WHITE, accent)
        val night = parsePalette(prefs.getString("fissio_widget_brand_night", null))
            ?: Palette(
                Color.parseColor("#FF1F1D1C"), Color.parseColor("#FFF3F2F2"), Color.parseColor("#FF9B9797"),
                accent, Color.WHITE,
            )
        return Style(theme, accent, day, night)
    }

    /** Widget zemini (köşeleri yuvarlak). */
    fun applyBackground(context: Context, views: RemoteViews, rootId: Int, style: Style) {
        when (style.theme) {
            Theme.SYSTEM -> views.setInt(rootId, "setBackgroundResource", R.drawable.widget_bg)
            Theme.LIGHT -> views.setInt(rootId, "setBackgroundResource", R.drawable.widget_bg_light)
            Theme.DARK -> views.setInt(rootId, "setBackgroundResource", R.drawable.widget_bg_dark)
            Theme.BRAND -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    views.setInt(rootId, "setBackgroundResource", R.drawable.widget_bg_tint)
                    // Gün/gece çifti: host çizim anında telefonun gece moduna göre seçer.
                    views.setColorStateList(
                        rootId,
                        "setBackgroundTintList",
                        ColorStateList.valueOf(style.day.bg),
                        ColorStateList.valueOf(style.night.bg),
                    )
                } else {
                    views.setInt(rootId, "setBackgroundColor", style.current(context).bg)
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
            Theme.BRAND -> {
                val day = if (mute) style.day.mute else style.day.ink
                val night = if (mute) style.night.mute else style.night.ink
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    views.setColorInt(textId, "setTextColor", day, night)
                } else {
                    val p = style.current(context)
                    views.setTextColor(textId, if (mute) p.mute else p.ink)
                }
                return
            }
        }
        views.setTextColor(textId, context.getColor(res))
    }

    /**
     * Eylem düğmesi: system/light/dark'ta marka renkli (layout varsayılanı). brand'de palete göre: açık palet = açık
     * zemin + marka renkli yazı/ikon; koyu palet = marka renkli zemin + beyaz (ya da koyu) yazı/ikon.
     */
    fun applyButton(context: Context, views: RemoteViews, buttonId: Int, iconId: Int, labelId: Int, style: Style) {
        if (style.theme != Theme.BRAND) return
        views.setInt(buttonId, "setBackgroundResource", R.drawable.widget_btn_inverse)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            views.setColorStateList(
                buttonId,
                "setBackgroundTintList",
                ColorStateList.valueOf(style.day.btnBg),
                ColorStateList.valueOf(style.night.btnBg),
            )
            views.setColorInt(labelId, "setTextColor", style.day.btnFg, style.night.btnFg)
            views.setColorInt(iconId, "setColorFilter", style.day.btnFg, style.night.btnFg)
        } else {
            val p = style.current(context)
            views.setInt(buttonId, "setBackgroundColor", p.btnBg)
            views.setTextColor(labelId, p.btnFg)
            views.setInt(iconId, "setColorFilter", p.btnFg)
        }
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
