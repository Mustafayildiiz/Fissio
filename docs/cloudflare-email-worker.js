// Fissio — Cloudflare Email Worker (e-posta ile otomatik fiş aktarımı).
// Kurulum, ortam değişkenleri ve "5.7.1" teşhis rehberi: docs/cloudflare-email-worker.md
//
// Tasarım kuralları:
// 1) Handler ASLA fırlatmaz. Email Worker'da yakalanmamış hata Cloudflare'in maili gönderene kalıcı ret (5.x.x) ile
//    döndürmesine yol açabilir; Gmail yönlendirmesinde bu, kullanıcıya "teslim edilemedi" bildirimi olarak yansır.
//    Mail zaten kullanıcının kendi kutusunda durduğundan, işlenemeyen mail günlüğe yazılır ve sessizce bırakılır.
// 2) Ham MIME bellekte string/base64'e çevrilmez: `message.raw` akışı doğrudan webhook'a `message/rfc822` olarak gider.
// 3) Boyut ÖNCEDEN `message.rawSize` ile denetlenir; sınırı aşan mailin gövdesi gönderilmez, sunucuya yalnız küçük bir
//    JSON bildirimi (`rejected: "too_large"`) gider ki kullanıcı uygulamadaki aktarım geçmişinde nedenini görsün.
// 4) Ret (`setReject`) yalnız REJECT_OVERSIZE=true ile ve yalnız aşırı boyutta, bilinçli olarak yapılır.

const CLOUDFLARE_MAX_BYTES = 25 * 1024 * 1024; // Email Routing'in kendi tavanı (25 MiB)
const DEFAULT_MAX_BYTES = 15 * 1024 * 1024; // sunucudaki INBOUND_MAX_BYTES varsayılanı
const TIMEOUT_MS = 60_000;

function maxBytesOf(env) {
  const n = Number(env.INBOUND_MAX_BYTES);
  const v = Number.isFinite(n) && n > 0 ? n : DEFAULT_MAX_BYTES;
  return Math.min(v, CLOUDFLARE_MAX_BYTES);
}

function webhookURL(env, rcpt) {
  // Mutlak yol ('/webhooks/...') FISSIO_API_BASE içindeki alt yolu (ör. https://host/api) atardı: yola eklenir.
  const url = new URL(String(env.FISSIO_API_BASE).replace(/\/+$/, '') + '/webhooks/inbound-email');
  url.searchParams.set('rcpt', rcpt); // zarf alıcısı: auto-forward'da To: başlığı kullanıcının kendi adresidir
  return url;
}

async function logResponse(res, message, size) {
  // Yanıt gövdesi okunmayacak: bağlantıyı/akışı serbest bırak (askıda kalan yanıt akışı uyarısını önler). Asla fırlatmaz.
  try {
    await res.body?.cancel();
  } catch (_) {}
  if (res.ok) return;
  if (res.status === 401) {
    console.error('fissio: webhook sırrı reddedildi (401); Worker ve sunucudaki INBOUND_WEBHOOK_SECRET değerlerini eşitle');
  } else if (res.status === 413) {
    console.error(`fissio: sunucu boyut sınırı nedeniyle reddetti (413) size=${size}; INBOUND_MAX_BYTES'i Worker ve sunucuda eşitle`);
  } else {
    console.error(`fissio: webhook ${res.status} döndü to=${message.to} size=${size}`);
  }
}

export default {
  // Bu Worker yalnız e-posta işler. Adresi tarayıcıdan açan biri (ya da favicon isteği) "Handler does not export a
  // fetch() function" hatası üretmesin diye zararsız bir yanıt döner; hiçbir değişkeni/sırrı açığa vurmaz.
  async fetch() {
    return new Response('Fissio inbound email worker', { status: 200 });
  },

  async email(message, env, ctx) {
    try {
      if (!env.FISSIO_API_BASE || !env.INBOUND_WEBHOOK_SECRET) {
        console.error('fissio: FISSIO_API_BASE / INBOUND_WEBHOOK_SECRET tanımlı değil; mail işlenmedi (ret yok)');
        return;
      }
      if (env.DEBUG_AUTH === 'true') {
        // SPF/DKIM/DMARC teşhisi: Cloudflare'in kendi sonucu `mx.cloudflare.net` ile başlayan ilk satırdır.
        console.log(`fissio: to=${message.to} auth=${message.headers.get('authentication-results')}`);
      }

      const maxBytes = maxBytesOf(env);
      const size = message.rawSize;
      const headers = { 'X-Webhook-Secret': env.INBOUND_WEBHOOK_SECRET };

      if (size > maxBytes) {
        console.warn(`fissio: mail çok büyük, gövde gönderilmedi (${size} > ${maxBytes} bayt) to=${message.to}`);
        // Gövdesiz bildirim: sunucu aktarım geçmişine "too_large" yazar. Başlıklar ham (RFC 2047) olabilir; sunucu çözer.
        // `from` zarf göndericisi DEĞİL, başlıktaki Gönderen'dir (Gmail iletiminde zarf = kullanıcının kendi/SRS adresi).
        try {
          const res = await fetch(webhookURL(env, message.to), {
            method: 'POST',
            headers: { ...headers, 'Content-Type': 'application/json' },
            body: JSON.stringify({
              to: message.to,
              from: message.headers.get('from') || '',
              subject: message.headers.get('subject') || '',
              rejected: 'too_large',
              size,
            }),
            signal: AbortSignal.timeout(TIMEOUT_MS),
          });
          await logResponse(res, message, size);
        } catch (err) {
          console.error(`fissio: boyut bildirimi gönderilemedi: ${err} to=${message.to}`);
        }
        if (env.REJECT_OVERSIZE === 'true') {
          message.setReject('Mesaj Fissio için çok büyük (boyut sınırı aşıldı).');
        }
        return;
      }

      // Ham MIME akışı doğrudan gövde: bellekte biriktirilmez (chunked). Uzunluk uyuşmazlığı riski taşıyan
      // FixedLengthStream ve ayrı bir pipe sözü (yakalanmamış ret) kullanılmaz.
      const res = await fetch(webhookURL(env, message.to), {
        method: 'POST',
        headers: { ...headers, 'Content-Type': 'message/rfc822' },
        body: message.raw,
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
      await logResponse(res, message, size);
      // Sunucu bilinmeyen alias / okunamayan maili de 200 `ignored` ile yanıtlar (yeniden deneme fırtınası olmasın).
    } catch (err) {
      // Ağ hatası, zaman aşımı, geçersiz FISSIO_API_BASE…: günlüğe yaz, maili REDDETME.
      console.error(`fissio: mail işlenemedi: ${err && err.stack ? err.stack : err} to=${message && message.to}`);
    }
  },
};
