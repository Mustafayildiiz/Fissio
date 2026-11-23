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

## Geliştirmede Quick Tunnel ile kullanım

Yerel expense servisi (`localhost:8082`) internete açık değildir; geliştirmede Worker ona Quick Tunnel ile ulaşır.

1. `cloudflared tunnel --url http://localhost:8082` çalıştır, pencereyi açık tut.
2. Adres çıktıda görünmüyorsa: `curl http://127.0.0.1:20241/quicktunnel` → `{"hostname":"x-y-z.trycloudflare.com"}` (metrics portu 20241-20250 arası seçilir).
3. Worker'da `FISSIO_API_BASE=https://x-y-z.trycloudflare.com` ayarla ve deploy et.
4. Doğrula: yanlış sırla `POST https://x-y-z.trycloudflare.com/webhooks/inbound-email` → `401`.

**Geçicidir:** tünel kapanır ya da bilgisayar yeniden başlarsa adres değişir; adım 3 yinelenir. Kalıcı çözüm: Cloudflare Zero Trust → Networks → Tunnels → `fissio` → `cloudflared service install <TOKEN>` (yönetici PowerShell) → Public Hostname `api.<alan>` (Path `webhooks/inbound-email`, Service `HTTP localhost:8082`) → Worker'da `FISSIO_API_BASE=https://api.<alan>`.

**Deploy sonrası kontrol listesi** (Worker kodunu "Edit code" ile yeniden deploy etmek Variables'ı silebilir): `FISSIO_API_BASE` dolu mu, `INBOUND_WEBHOOK_SECRET` (Secret) `.env` ile aynı mı, eski `WEBHOOK_URL` gibi kullanılmayan değişkenler silindi mi.

**Sır üretimi:** düz hex kullan (`openssl rand -hex 32`). Değiştirince `.env`'i kaydet ve `docker compose up -d --no-build --force-recreate expense` ile expense'i yeniden oluştur; konteyner değeri yalnızca başlarken okur.

Worker'ın `fetch` işleyicisi yalnızca `200 "Fissio inbound email worker"` döner (adresi tarayıcıdan açan biri hata günlüğü üretmesin diye); mail akışı `email` işleyicisindedir.

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
7. Activity Log'da mail **Handled** görünüyor ama fiş oluşmuyorsa sorun Worker'a ulaşmadan değil, Worker'dan sonradır: Worker günlüğünü (Workers → Logs) aç. `tanımlı değil` = Variables silinmiş; `401` = sır uyuşmuyor; `fetch failed` = tünel kapalı. Sunucuda karşılığı: `expense.inbound_history` tablosunda satır yoksa istek hiç ulaşmamıştır.

Kullanıcıya yönelik açıklama uygulamadaki Destek > SSS'dedir ("Gönderim 5.7.1 / teslim edilemedi hatası").
