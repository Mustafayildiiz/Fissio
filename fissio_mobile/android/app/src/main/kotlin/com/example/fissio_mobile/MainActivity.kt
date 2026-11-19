package com.example.fissio_mobile

import android.content.ComponentName
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /**
     * Uygulama arka plandayken (ya da süreci sistem tarafından öldürülmüşken) widget'a dokunulunca görev zaten
     * vardır ve `singleTop` yüzünden yeni intent [onNewIntent]'e gelir. `Activity.getIntent()` güncellenmezse
     * `home_widget`'ın `initiallyLaunchedFromHomeWidget` çağrısı eski (MAIN) intent'i okur ve `fissio://scan`
     * kaybolur; bu yüzden en yeni intent kaydedilir.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "supported" -> result.success(!isDebuggable())
                "set" -> {
                    val key = call.argument<String>("key")
                    if (isDebuggable()) {
                        result.success(false)
                    } else if (key != null && ALIASES.containsKey(key)) {
                        result.success(selectLauncherIcon(key))
                    } else {
                        result.error("bad_key", "Bilinmeyen ikon anahtarı: $key", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Debug sürümlerinde ikon değiştirilmez: kırmızı dışındaki bir renkte MainActivity devre dışı kalır ve
     * `flutter run` (am start .../MainActivity) "Activity class does not exist" ile başlatamaz. Yayın
     * (release/profile) sürümlerinde değiştirme açıktır.
     */
    private fun isDebuggable(): Boolean = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    /**
     * Seçilen renge ait başlatıcı girişini etkinleştirir, diğerlerini devre dışı bırakır (aynı anda tek ikon).
     * Kırmızı = MainActivity'nin kendi LAUNCHER girişi; diğer renkler activity-alias'tır. DONT_KILL_APP ile
     * uygulama kapanmaz; ana ekran ikonu başlatıcının yenilemesiyle birkaç saniye içinde değişir.
     * Önce yeni giriş açılır, sonra eskiler kapatılır (ikon bir an bile kaybolmasın). Uygulama içi başlatmalar
     * (widget, bildirim) bileşen adına değil `getLaunchIntentForPackage`'a dayanır, bu yüzden hangi girişin
     * etkin olduğu fark etmez.
     */
    private fun selectLauncherIcon(key: String): Boolean {
        return try {
            val pm = packageManager
            // Takma adlar SINIF (namespace) paketindedir; applicationId (packageName) farklı olabilir, bu yüzden bileşen
            // sınıf adı `$packageName` değil MainActivity'nin paketinden türetilir.
            val classPackage = MainActivity::class.java.name.substringBeforeLast('.')
            fun component(name: String) = ComponentName(packageName, "$classPackage.$name")
            pm.setComponentEnabledSetting(
                component(ALIASES.getValue(key)),
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP,
            )
            for ((k, name) in ALIASES) {
                if (k == key) continue
                pm.setComponentEnabledSetting(
                    component(name),
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP,
                )
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    companion object {
        const val CHANNEL = "fissio/launcher_icon"

        /** Dart tarafındaki `kBrandPalette` anahtarları → başlatıcı girişi (bileşen) adları. */
        val ALIASES = mapOf(
            "red" to "MainActivity",
            "purple" to "LauncherPurple",
            "green" to "LauncherGreen",
            "darkred" to "LauncherDarkred",
            "blue" to "LauncherBlue",
            "graphite" to "LauncherGraphite",
            "ink" to "LauncherInk",
        )
    }
}
