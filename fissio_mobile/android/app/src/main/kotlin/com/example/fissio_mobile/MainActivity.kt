package com.example.fissio_mobile

import android.content.ComponentName
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var shareChannel: MethodChannel? = null

    /**
     * Uygulama arka plandayken (ya da süreci sistem tarafından öldürülmüşken) widget'a dokunulunca görev zaten
     * vardır ve `singleTop` yüzünden yeni intent [onNewIntent]'e gelir. `Activity.getIntent()` güncellenmezse
     * `home_widget`'ın `initiallyLaunchedFromHomeWidget` çağrısı eski (MAIN) intent'i okur ve `fissio://scan`
     * kaybolur; bu yüzden en yeni intent kaydedilir.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Uygulama açıkken başka bir uygulamadan "Paylaş → Fissio" ile PDF/.eml/HTML geldi: Dart tarafına yerel yolu ilet.
        extractSharedFile(intent)?.let { path ->
            shareChannel?.invokeMethod("onFile", path)
            clearSharedIntent()
        }
    }

    /**
     * "Paylaş → Fissio" (ACTION_SEND) ve "Birlikte aç" (ACTION_VIEW) ile gelen dijital fişi (PDF, .eml e-posta ya da HTML
     * sipariş özeti) uygulama önbelleğine kopyalar ve yerel yolunu döner (yoksa null). Önbellek dosyasının UZANTISI MIME türünden
     * gelir (.pdf / .eml / .html): Dart tarafı dosyayı uzantısına göre ayrıştırır. Dosya hiçbir yere gönderilmez; okuma cihaz
     * içidir. 20 MB üstü ve desteklenmeyen türler reddedilir. Eski kopyalar (>1 gün) silinir.
     *
     * `ACTION_SEND` + `text/html` çoğu zaman `EXTRA_STREAM` olmadan, HTML'i `EXTRA_HTML_TEXT` / `EXTRA_TEXT` içinde taşır: bu
     * durumda metin `.html` dosyasına yazılır.
     */
    private fun extractSharedFile(intent: Intent?): String? {
        if (intent == null) return null
        val uri: Uri? = when (intent.action) {
            Intent.ACTION_SEND ->
                if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
            Intent.ACTION_VIEW -> intent.data
            else -> null
        }
        if (uri?.scheme == "fissio") return null
        return try {
            val type = (intent.type ?: uri?.let { contentResolver.getType(it) })?.lowercase()
            val ext = SHARED_TYPES[type] ?: return null
            val dir = File(cacheDir, "shared").apply { mkdirs() }
            val cutoff = System.currentTimeMillis() - 24L * 60 * 60 * 1000
            dir.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.delete() }
            val out = File(dir, "shared_${System.currentTimeMillis()}.$ext")
            if (uri == null) {
                // Akış yok: HTML gövde metin olarak gelmiştir.
                if (intent.action != Intent.ACTION_SEND || ext != "html") return null
                val body = intent.getStringExtra(Intent.EXTRA_HTML_TEXT) ?: intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                if (body.isNullOrBlank()) return null
                val bytes = body.toByteArray(Charsets.UTF_8)
                if (bytes.size > MAX_SHARED_BYTES) return null
                out.writeBytes(bytes)
                return out.absolutePath
            }
            var total = 0L
            contentResolver.openInputStream(uri)?.use { input ->
                out.outputStream().use { output ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > MAX_SHARED_BYTES) {
                            out.delete()
                            return null
                        }
                        output.write(buf, 0, n)
                    }
                }
            } ?: return null
            out.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    /** Tüketilen paylaşım intent'i yeniden işlenmesin (ekran dönmesi / yeniden oluşturma). */
    private fun clearSharedIntent() {
        setIntent(Intent(intent).apply {
            action = Intent.ACTION_MAIN
            data = null
            type = null
            removeExtra(Intent.EXTRA_STREAM)
            removeExtra(Intent.EXTRA_TEXT)
            removeExtra(Intent.EXTRA_HTML_TEXT)
        })
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        PdfChannel.register(this, flutterEngine.dartExecutor.binaryMessenger)
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    // Soğuk açılış: uygulama paylaşılan dosyayla (PDF/.eml/HTML) başlatıldıysa yolu ver (bir kez).
                    "getInitialFile" -> {
                        val path = extractSharedFile(intent)
                        if (path != null) clearSharedIntent()
                        result.success(path)
                    }
                    else -> result.notImplemented()
                }
            }
        }
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
        /** Paylaşım ile kabul edilen MIME türleri → önbellek dosyası uzantısı (AndroidManifest filtreleriyle aynı küme). */
        private val SHARED_TYPES = mapOf(
            "application/pdf" to "pdf",
            "message/rfc822" to "eml",
            "text/html" to "html",
        )

        const val CHANNEL = "fissio/launcher_icon"
        const val SHARE_CHANNEL = "fissio/share_intent"
        const val MAX_SHARED_BYTES = 20L * 1024 * 1024

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
