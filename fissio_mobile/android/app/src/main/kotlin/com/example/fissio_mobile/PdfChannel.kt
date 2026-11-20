package com.example.fissio_mobile

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import com.tom_roush.pdfbox.text.PDFTextStripper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/**
 * Dijital fiş / e-fatura (PDF) okuyucu köprüsü (`fissio/pdf`, Dart: lib/services/pdf_reader.dart). Her şey cihazda
 * yapılır; dosya hiçbir yere gönderilmez.
 *
 *  - `readText(path, maxPages)`: PdfBox-Android ile sayfa başına metin katmanı (taranmış PDF'te boş/kısa).
 *  - `renderPages(path, maxPages)`: sistemin `PdfRenderer`'ı ile sayfaları PNG'ye çevirir (~1600 px uzun kenar);
 *    taranmış PDF Dart tarafında OCR hattına düşer.
 * Ağır işler ana iş parçacığını bloklamasın diye tek iş parçacıklı bir yürütücüde çalışır.
 */
object PdfChannel {
    const val CHANNEL = "fissio/pdf"
    private const val MAX_RENDER_SIDE = 1600
    private val executor = Executors.newSingleThreadExecutor()

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            val path = call.argument<String>("path")
            val maxPages = call.argument<Int>("maxPages") ?: 6
            if (path == null || !File(path).isFile) {
                result.error("bad_path", "PDF dosyası bulunamadı", null)
                return@setMethodCallHandler
            }
            executor.execute {
                try {
                    val out: Any = when (call.method) {
                        "readText" -> readText(app, path, maxPages)
                        "renderPages" -> renderPages(path, maxPages)
                        else -> {
                            main(app) { result.notImplemented() }
                            return@execute
                        }
                    }
                    main(app) { result.success(out) }
                } catch (e: InvalidPasswordException) {
                    main(app) { result.error("encrypted", "PDF parola korumalı", null) }
                } catch (e: Exception) {
                    main(app) { result.error("read_failed", e.message ?: "PDF okunamadı", null) }
                }
            }
        }
    }

    private fun main(context: Context, block: () -> Unit) =
        android.os.Handler(context.mainLooper).post(block)

    private fun readText(context: Context, path: String, maxPages: Int): List<String> {
        PDFBoxResourceLoader.init(context)
        PDDocument.load(File(path)).use { doc ->
            val stripper = PDFTextStripper().apply { sortByPosition = true }
            val pages = minOf(doc.numberOfPages, maxPages)
            return (1..pages).map { n ->
                stripper.startPage = n
                stripper.endPage = n
                stripper.getText(doc)
            }
        }
    }

    private fun renderPages(path: String, maxPages: Int): List<ByteArray> {
        val pfd = ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        PdfRenderer(pfd).use { renderer ->
            val pages = minOf(renderer.pageCount, maxPages)
            return (0 until pages).map { i ->
                renderer.openPage(i).use { page ->
                    val scale = MAX_RENDER_SIDE.toFloat() / maxOf(page.width, page.height)
                    val bmp = Bitmap.createBitmap(
                        (page.width * scale).toInt().coerceAtLeast(1),
                        (page.height * scale).toInt().coerceAtLeast(1),
                        Bitmap.Config.ARGB_8888,
                    )
                    bmp.eraseColor(Color.WHITE) // PdfRenderer şeffaf bırakır: OCR için beyaz zemin
                    page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    ByteArrayOutputStream().use { bos ->
                        bmp.compress(Bitmap.CompressFormat.PNG, 100, bos)
                        bmp.recycle()
                        bos.toByteArray()
                    }
                }
            }
        }
    }
}
