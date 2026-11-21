// Fissio — Cloudflare Email Worker (e-posta ile otomatik fiş aktarımı).
// Kurulum ve ortam değişkenleri: docs/cloudflare-email-worker.md
//
// Neden ham MIME akışı? Önceki yaklaşım maili tamamen string'e çevirip JSON/base64'e koyuyordu: büyük ekli mailler Worker
// belleğini (128 MB) zorlar ve base64 gövdeyi %33 şişirdiği için sunucunun boyut sınırını (INBOUND_MAX_BYTES, 413) aşardı.
// Burada `message.raw` akışı doğrudan webhook'a `message/rfc822` olarak borulanır (bellekte tutulmaz) ve boyut ÖNCEDEN
// `message.rawSize` ile denetlenir. Alıcı (zarf) adresi `?rcpt=` ile iletilir; sunucu alias'ı oradan çözer.

export default {
  async email(message, env, ctx) {
    // Sunucudaki INBOUND_MAX_BYTES ile aynı olmalı (varsayılan 15 MB).
    const maxBytes = Number(env.INBOUND_MAX_BYTES || 15 * 1024 * 1024);

    if (message.rawSize > maxBytes) {
      // Büyük ekli mail: işlenmez. Mail kullanıcının kendi kutusunda durur (yönlendirme bir kopyadır); hata günlüğe düşer.
      console.warn(
        `fissio: mail çok büyük, atlandı (${message.rawSize} > ${maxBytes} bayt) from=${message.from} to=${message.to}`,
      );
      // İsteğe bağlı: REJECT_OVERSIZE=true ise gönderene kalıcı ret (5.x.x) döner; varsayılan sessiz atlamadır
      // (Gmail yönlendirmesinde ret, kullanıcıya "teslim edilemedi" bildirimi olarak döner).
      if (env.REJECT_OVERSIZE === 'true') message.setReject('Mesaj Fissio için çok büyük (boyut sınırı aşıldı).');
      return;
    }

    const url = new URL('/webhooks/inbound-email', env.FISSIO_API_BASE);
    url.searchParams.set('rcpt', message.to); // zarf alıcısı: auto-forward'da To: başlığı kullanıcının kendi adresidir

    // Bilinen uzunlukta akış: sunucuya Content-Length ile gider, chunked/bellekte biriktirme olmaz.
    const { readable, writable } = new FixedLengthStream(message.rawSize);
    const pipe = message.raw.pipeTo(writable);

    let res;
    try {
      res = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'message/rfc822',
          'X-Webhook-Secret': env.INBOUND_WEBHOOK_SECRET,
        },
        body: readable,
      });
      await pipe;
    } catch (err) {
      console.error(`fissio: webhook çağrısı başarısız: ${err} to=${message.to}`);
      return;
    }

    if (res.status === 413) {
      console.warn(`fissio: sunucu boyut sınırını aştığı için reddetti (413) size=${message.rawSize}; INBOUND_MAX_BYTES'i eşitle`);
    } else if (res.status === 401) {
      console.error('fissio: webhook sırrı reddedildi (401); INBOUND_WEBHOOK_SECRET değerlerini eşitle');
    } else if (!res.ok) {
      console.error(`fissio: webhook ${res.status} döndü to=${message.to}`);
    }
    // Sunucu bilinmeyen alias / okunamayan maili de 200 `ignored` ile yanıtlar (yeniden deneme fırtınası olmasın).
  },
};
