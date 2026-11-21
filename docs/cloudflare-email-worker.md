# Cloudflare Email Worker kurulumu

`docs/cloudflare-email-worker.js`, `INBOUND_EMAIL_DOMAIN` altına gelen mailleri Fissio'nun
`POST /webhooks/inbound-email` ucuna iletir.

## Kurulum

1. Cloudflare'de alan adı için **Email Routing**'i aç; `*@fis.ornek.app` (catch-all) kuralını bu Worker'a yönlendir.
2. Worker ortam değişkenleri:
   - `FISSIO_API_BASE` — örn. `https://api.ornek.app` (expense servisine giden kök adres)
   - `INBOUND_WEBHOOK_SECRET` — sunucudaki `INBOUND_WEBHOOK_SECRET` ile aynı (Secret olarak tanımla)
   - `INBOUND_MAX_BYTES` — sunucudakiyle aynı (varsayılan `15728640` = 15 MB)
   - `REJECT_OVERSIZE` — isteğe bağlı; `true` ise çok büyük mail gönderene kalıcı ret ile döner
3. Sunucuda `INBOUND_EMAIL_DOMAIN` ve `INBOUND_WEBHOOK_SECRET` dolu olmalı (`.env.example`).

## Büyük ekli ve "5.7.1 / teslim edilemedi" mailleri

- Worker maili string'e çevirmez; `message.raw` akışını `message/rfc822` olarak borular, boyutu önce `message.rawSize` ile
  denetler. Sınırı aşan mail **atlanır ve günlüğe yazılır** (`wrangler tail`), kullanıcının kendi kutusunda durur.
- `REJECT_OVERSIZE=true` yapılırsa gönderene `5.x.x` kalıcı ret döner. Gmail yönlendirmesinde bu, kullanıcıya "teslim
  edilemedi" bildirimi olarak yansır; varsayılan bu yüzden sessiz atlamadır.
- Kullanıcıya yönelik açıklama uygulamadaki Destek > SSS'dedir ("Gönderim 5.7.1 / teslim edilemedi hatası").
- Sunucu 413 dönerse `INBOUND_MAX_BYTES` değerlerinin Worker ve sunucuda eşit olduğundan emin ol.
