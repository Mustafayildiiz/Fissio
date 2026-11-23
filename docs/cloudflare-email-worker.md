# Cloudflare Email Worker kurulumu

`docs/cloudflare-email-worker.js`, `INBOUND_EMAIL_DOMAIN` altına gelen mailleri Fissio'nun
`POST /webhooks/inbound-email` ucuna iletir.

## Kurulum / güncelleme

1. Cloudflare'de **Email Routing**'i `INBOUND_EMAIL_DOMAIN`'in **tam alan adı** için aç (alias `x@fis.ornek.app` ise
   Email Routing ve MX kayıtları `fis.ornek.app` için kurulu olmalı; yalnız `ornek.app` yetmez).
2. Workers & Pages → Worker → **Edit code** → bu dosyanın içeriğini yapıştır → **Deploy**.
3. Email → Email Routing → Routing rules → **Catch-all** → Action: *Send to a Worker* → bu Worker; durumu *Active*.
4. Worker → Settings → Variables and Secrets:

| Değişken | Açıklama |
|---|---|
| `FISSIO_API_BASE` | Expense servisine giden kök adres, örn. `https://api.ornek.app` (eksikse mail işlenmez, ret YOK, günlüğe yazılır) |
| `INBOUND_WEBHOOK_SECRET` | **Secret** olarak; sunucudaki `INBOUND_WEBHOOK_SECRET` ile birebir aynı |
| `INBOUND_MAX_BYTES` | Sunucudakiyle aynı (varsayılan `15728640` = 15 MB); Cloudflare tavanı 25 MiB, üstü kırpılır |
| `REJECT_OVERSIZE` | İsteğe bağlı; `true` ise sınırı aşan mail gönderene kalıcı ret ile döner (varsayılan: ret yok) |
| `DEBUG_AUTH` | İsteğe bağlı; `true` ise `Authentication-Results` başlığını günlüğe yazar (SPF/DKIM teşhisi) |

5. Sunucuda `INBOUND_EMAIL_DOMAIN` ve `INBOUND_WEBHOOK_SECRET` dolu olmalı (`.env.example`).

## Davranış

- Handler **asla fırlatmaz**: yakalanmamış Worker hatası Cloudflare'in maili gönderene ret ile döndürmesine yol açabilir.
  Ağ hatası, zaman aşımı (60 sn), sunucunun 401/413/5xx yanıtı → yalnız günlük (`wrangler tail` / Worker Logs).
- Mail string'e çevrilmez; `message.raw` akışı doğrudan `message/rfc822` gövdesi olarak gider, alıcı `?rcpt=` ile.
- Sınırı aşan mailin gövdesi gönderilmez; sunucuya küçük bir JSON bildirimi gider
  (`{to, from, subject, rejected: "too_large", size}`) ve kullanıcı uygulamadaki **Son Aktarılan E-Postalar**
  listesinde "Çok Büyük" satırını görür. Mail kendi kutusunda durur; fişi Paylaş → Fissio ile eklenebilir.

## "5.7.1 / message rejected" teşhis rehberi

5.7.1 çoğunlukla mail Worker'a ulaşmadan Cloudflare tarafından verilir. Sırayla kontrol et:

1. **Email Routing → Activity Log**: ilgili mailin durumu (*Delivered / Rejected / Dropped*) ve nedeni. Kök neden buradan
   okunmadan kesinleşmez.
2. **Kimlik doğrulama**: Cloudflare gelen mailde SPF **ya da** DKIM'in geçmesini ister ve gönderen alan adının DMARC
   politikasını uygular. İkisi de geçmezse ya da DMARC `p=reject` ise mail reddedilir. Gmail/Outlook gibi büyük
   sağlayıcılar geçer; kurumsal/özel alan adları ve SPF'siz sunuculardan gelen iletimler takılabilir. `DEBUG_AUTH=true`
   ile `mx.cloudflare.net; spf=… dkim=… dmarc=…` satırına bak.
3. **Alan adı / kural**: Email Routing ve MX kayıtları `INBOUND_EMAIL_DOMAIN`'in tam alan adında mı? Catch-all kuralı
   etkin ve bu Worker'a mı bağlı? Kural yoksa adres "bulunamadı" ile reddedilir.
4. **Worker sürümü**: Panelde bu dosyanın güncel hali deploy edilmiş mi? Eski sürüm (`FixedLengthStream` + try dışındaki
   `new URL`) env eksikken fırlatıp rete yol açabiliyordu.
5. **Boyut**: Cloudflare 25 MiB üstünü reddeder; `REJECT_OVERSIZE=true` ise Worker da `INBOUND_MAX_BYTES` üstünü reddeder.
6. Sunucu 401 dönüyorsa sırlar, 413 dönüyorsa `INBOUND_MAX_BYTES` değerleri uyuşmuyor (Worker günlüğünde yazar).

Kullanıcıya yönelik açıklama uygulamadaki Destek > SSS'dedir ("Gönderim 5.7.1 / teslim edilemedi hatası").
