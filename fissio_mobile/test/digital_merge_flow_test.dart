import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fissio_mobile/api.dart';
import 'package:fissio_mobile/data/data_transfer.dart';
import 'package:fissio_mobile/models.dart';
import 'package:fissio_mobile/ocr/ocr_engine.dart';
import 'package:fissio_mobile/services/pdf_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';
import 'support/fakes.dart';

// Dijital fiş: ön özet (HTML sipariş özeti) + sonradan gelen resmi fatura birleştirmesi, mükerrer reddi ve .eml/.html okuma.
// Karar mantığı Go ile ortak vektörlerle (digital_golden_test.dart) sınanır; burada AppState entegrasyonu (çevrimiçi, çevrimdışı,
// senkron kapalı, bayat önbellek, toplu kuyruk boşaltma) doğrulanır.

const _email = 'ali@x.co';
const _ettn1 = '3f2a9c1e-5b7d-4e8a-9c3d-1a2b3c4d5e6f';
const _ettn2 = '11111111-2222-4333-8444-555555555555';

ReceiptDraft _draft(
  String merchant,
  double amount, {
  String? documentNo,
  String? orderId,
  DateTime? date,
  String? uid,
  List<ExpenseItem>? items,
}) => ReceiptDraft(
  clientUid: uid,
  merchant: merchant,
  categoryId: 1,
  date: date ?? DateTime(2026, 11, 14),
  items: items ?? [ExpenseItem('Tavuk Döner', amount - 25), ExpenseItem('Ayran', 25)],
  documentNo: documento(documentNo),
  orderId: orderId,
);

String? documento(String? v) => v;

Future<Harness> _signedIn({FakeBackend? backend, bool syncOn = true}) async {
  final h = Harness(backend: backend, clock: () => DateTime(2026, 11, 20));
  await h.signIn(_email);
  if (!syncOn) await h.app.setSyncEnabled(false);
  return h;
}

void main() {
  group('çevrimiçi (senkron açık)', () {
    test('ön özet + resmi fatura: yeni kayıt açılmaz, ön özet güncellenip kilitlenir', () async {
      final h = await _signedIn();
      final pre = await h.app.saveDraft(_draft('Yemeksepeti', 210, orderId: 'YS-4F7A91C2', uid: 'pre-1'));
      expect(pre.merged, isFalse);
      final r = await h.app.saveDraft(_draft('Köşebaşı Döner Ltd.', 212.5, orderId: 'YS-4F7A91C2', documentNo: _ettn1, date: DateTime(2026, 11, 17), uid: 'off-1'));
      expect(r.merged, isTrue);

      expect(h.app.expenses, hasLength(1), reason: 'tek kayıt');
      final e = h.app.expenses.single;
      expect(e.merchant, 'Yemeksepeti', reason: 'kullanıcının işletme adı ezilmez');
      expect(e.date, DateTime(2026, 11, 14));
      expect(e.amount, 212.5, reason: 'resmi kesin toplam');
      expect(e.documentNo, _ettn1);
      expect(e.orderId, 'YS-4F7A91C2');
      expect(e.hasOfficialInvoice, isTrue);
      expect(h.backend.expensesOf(_email), hasLength(1));
      expect(h.backend.expensesOf(_email).single['has_official_invoice'], isTrue);
      // KDV'siz kalem toplamı: fark ayrı "KDV" kalemi (kaydedilen tutar resmi toplam).
      expect(e.items.map((i) => i.name), contains('KDV'));
    });

    test('mükerrer: aynı sipariş (aynı tür), aynı ETTN, resmi kayıt varken ön özet → reddedilir', () async {
      final h = await _signedIn();
      await h.app.saveDraft(_draft('Yemeksepeti', 210, orderId: 'YS-1', uid: 'a'));
      await expectLater(
        h.app.saveDraft(_draft('Yemeksepeti', 210, orderId: 'YS-1', uid: 'b')),
        throwsA(isA<ApiException>().having((e) => e.duplicateOrder, 'duplicateOrder', isTrue)),
      );
      await h.app.saveDraft(_draft('Restoran', 212.5, orderId: 'YS-1', documentNo: _ettn1, uid: 'c')); // birleşir
      await expectLater(
        h.app.saveDraft(_draft('Restoran', 212.5, orderId: 'YS-1', documentNo: _ettn2, uid: 'd')),
        throwsA(isA<ApiException>().having((e) => e.duplicateOrder, 'üçüncü belge', isTrue)),
      );
      await expectLater(
        h.app.saveDraft(_draft('Restoran', 99, documentNo: _ettn1, uid: 'e')),
        throwsA(isA<ApiException>().having((e) => e.duplicateDocument, 'aynı ETTN', isTrue)),
      );
      await expectLater(
        h.app.saveDraft(_draft('Yemeksepeti', 210, orderId: 'YS-1', uid: 'f')),
        throwsA(isA<ApiException>().having((e) => e.duplicateOrder, 'resmi varken ön özet', isTrue)),
      );
      expect(h.app.expenses, hasLength(1));
    });

    test('aynı gün iki farklı sipariş birleşmez; farklı order_id asla birleşmez', () async {
      final h = await _signedIn();
      await h.app.saveDraft(_draft('Köşebaşı Döner', 210, orderId: 'YS-A111', uid: 'a'));
      await h.app.saveDraft(_draft('Köşebaşı Döner', 210, orderId: 'YS-B222', uid: 'b'));
      // order_id'siz resmi fatura: iki aday → belirsiz → ayrı kayıt.
      final r = await h.app.saveDraft(_draft('Köşebaşı Döner', 210, documentNo: _ettn1, uid: 'c'));
      expect(r.merged, isFalse);
      expect(h.app.expenses, hasLength(3));
      // Farklı order_id'li resmi fatura da (tutar/gün aynı) hiçbirine birleşmez.
      final r2 = await h.app.saveDraft(_draft('Köşebaşı Döner', 210, documentNo: _ettn2, orderId: 'YS-C333', uid: 'd'));
      expect(r2.merged, isFalse);
      expect(h.app.expenses, hasLength(4));
      expect(h.app.expenses.where((e) => e.hasOfficialInvoice), hasLength(2));
    });

    test('bayat önbellek + dolu hedef: PUT farklı belgeyi ezemez (document_locked), resmi kayıt değişmez', () async {
      final a = await _signedIn();
      final b = await _signedIn(backend: a.backend);
      await a.app.saveDraft(_draft('Yemeksepeti', 210, orderId: 'YS-LK', uid: 'pre'));
      await b.app.refresh(); // B özeti ön özet olarak görür
      // A resmi belgeyi bağlar (ETTN1); B'nin önbelleği hâlâ "ön özet" diyor.
      await a.app.saveDraft(_draft('Restoran', 212.5, orderId: 'YS-LK', documentNo: _ettn1, uid: 'off1'));
      expect(b.app.expenses.single.hasOfficialInvoice, isFalse, reason: 'B bayat');
      await expectLater(
        b.app.saveDraft(_draft('Restoran', 212.5, orderId: 'YS-LK', documentNo: _ettn2, uid: 'off2')),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'document_locked')),
      );
      expect(a.backend.expensesOf(_email).single['document_no'], _ettn1);
    });

    test('bayat önbellek: sunucu birleştirir (merged), istemci hedef kaydı günceller', () async {
      final a = await _signedIn();
      final b = await _signedIn(backend: a.backend); // 2. cihaz: henüz ön özeti görmedi
      await a.app.saveDraft(_draft('Yemeksepeti', 210, orderId: 'YS-9', uid: 'pre'));
      expect(b.app.expenses, isEmpty, reason: 'B önbelleği bayat');
      final r = await b.app.saveDraft(_draft('Restoran', 212.5, orderId: 'YS-9', documentNo: _ettn1, uid: 'off'));
      expect(r.merged, isTrue, reason: 'sunucu kararı');
      expect(a.backend.expensesOf(_email), hasLength(1));
      expect(b.app.expenses.single.hasOfficialInvoice, isTrue);
    });
  });

  group('senkron kapalı (yalnızca cihaz)', () {
    test('yerel ön özet + resmi fatura cihazda birleşir', () async {
      final h = await _signedIn(syncOn: false);
      await h.app.saveDraft(_draft('Yemeksepeti', 210, orderId: 'YS-7', uid: 'pre'));
      expect(h.app.expenses.single.syncState, SyncState.localOnly);
      final r = await h.app.saveDraft(_draft('Restoran', 212.5, orderId: 'YS-7', documentNo: _ettn1, uid: 'off'));
      expect(r.merged, isTrue);
      expect(h.app.expenses, hasLength(1));
      expect(h.app.expenses.single.documentNo, _ettn1);
      expect(h.app.expenses.single.amount, 212.5);
      expect(h.backend.expensesOf(_email), isEmpty, reason: 'sunucuya hiçbir şey yazılmaz');
    });

    test('yerel mükerrer: aynı sipariş ve aynı belge reddedilir', () async {
      final h = await _signedIn(syncOn: false);
      await h.app.saveDraft(_draft('Yemeksepeti', 210, orderId: 'YS-7', uid: 'a'));
      await expectLater(h.app.saveDraft(_draft('Yemeksepeti', 210, orderId: 'YS-7', uid: 'b')), throwsA(isA<ApiException>().having((e) => e.duplicateOrder, 'order', isTrue)));
      await h.app.saveDraft(_draft('X', 50, documentNo: _ettn2, uid: 'c'));
      await expectLater(h.app.saveDraft(_draft('Y', 60, documentNo: _ettn2, uid: 'd')), throwsA(isA<ApiException>().having((e) => e.duplicateDocument, 'doc', isTrue)));
    });
  });

  group('senkron kapalı + bulut ön özeti', () {
    test('bulut kaydı salt okunur: resmi fatura hata vermez, yerel kaydedilir; senkron açılınca sunucu birleştirir', () async {
      final h = await _signedIn();
      await h.app.saveDraft(_draft('Yemeksepeti', 210, orderId: 'YS-OFF', uid: 'pre'));
      expect(h.app.expenses.single.syncState, SyncState.synced, reason: 'ön özet bulutta (ör. webhook ile geldi)');

      await h.app.setSyncEnabled(false);
      final r = await h.app.saveDraft(_draft('Restoran', 212.5, orderId: 'YS-OFF', documentNo: _ettn1, uid: 'off'));
      expect(r.localOnly, isTrue, reason: 'readOnlyCloudMessage fırlatılmaz; yerel kayıt');
      expect(r.merged, isFalse);
      expect(h.app.expenses, hasLength(2), reason: 'bulut ön özeti + yerel resmi fatura');
      expect(h.backend.expensesOf(_email), hasLength(1), reason: 'senkron kapalıyken sunucuya hiçbir şey yazılmaz');

      // Senkron açılır: yerel kayıt kuyruğa alınır ve toplu yüklemede SUNUCU aynı kararla birleştirir.
      await h.app.setSyncEnabled(true);
      await h.app.flushNow(force: true);
      final server = h.backend.expensesOf(_email);
      expect(server, hasLength(1), reason: 'yeni kayıt açılmadı');
      expect(server.single['has_official_invoice'], isTrue);
      expect(server.single['document_no'], _ettn1);
      expect(h.app.pendingCount, 0);
      expect(h.app.expenses, hasLength(1));
      expect(h.app.expenses.single.hasOfficialInvoice, isTrue);
    });
  });

  group('çevrimdışı kuyruk', () {
    test('önbellekteki ön özete çevrimdışı birleştirme: bekleyen düzenleme olur, bağlantıda PUT ile buluta gider', () async {
      final h = await _signedIn();
      await h.app.saveDraft(_draft('Yemeksepeti', 210, orderId: 'YS-5', uid: 'pre'));
      h.backend.offline = true;
      final r = await h.app.saveDraft(_draft('Restoran', 212.5, orderId: 'YS-5', documentNo: _ettn1, uid: 'off'));
      expect(r.merged, isTrue);
      expect(r.queued, isTrue, reason: 'çevrimdışı: düzenleme kuyruğa alındı');
      expect(h.app.expenses, hasLength(1));
      expect(h.app.expenses.single.documentNo, _ettn1, reason: 'yerel görünüm birleşmiş hâli gösterir');
      expect(h.backend.expensesOf(_email).single['document_no'], isNull);

      h.backend.offline = false;
      await h.app.flushNow(force: true);
      final server = h.backend.expensesOf(_email);
      expect(server, hasLength(1));
      expect(server.single['document_no'], _ettn1);
      expect(server.single['has_official_invoice'], isTrue);
      expect(h.app.pendingCount, 0);
    });

    test('toplu kuyruk boşaltma: sunucu resmi faturayı mevcut ön özete birleştirir (merged), yerel kopya kuyruktan çıkar', () async {
      final a = await _signedIn();
      final b = await _signedIn(backend: a.backend);
      await a.app.saveDraft(_draft('Yemeksepeti', 210, orderId: 'YS-6', uid: 'pre'));
      a.backend.offline = true;
      final r = await b.app.saveDraft(_draft('Restoran', 212.5, orderId: 'YS-6', documentNo: _ettn1, uid: 'off'));
      expect(r.queued, isTrue);
      expect(b.app.pendingCount, 1);

      a.backend.offline = false;
      await b.app.flushNow(force: true);
      expect(b.app.pendingCount, 0, reason: 'merged = başarılı');
      final server = a.backend.expensesOf(_email);
      expect(server, hasLength(1), reason: 'yeni kayıt açılmadı');
      expect(server.single['document_no'], _ettn1);
      expect(b.app.expenses, hasLength(1));
      expect(b.app.expenses.single.hasOfficialInvoice, isTrue);
    });

    test('toplu kuyruk: mükerrer sipariş kuyrukta kalır ve anlaşılır bir hata taşır', () async {
      final a = await _signedIn();
      final b = await _signedIn(backend: a.backend);
      await a.app.saveDraft(_draft('Yemeksepeti', 210, orderId: 'YS-8', uid: 'pre'));
      a.backend.offline = true;
      await b.app.saveDraft(_draft('Yemeksepeti', 210, orderId: 'YS-8', uid: 'dup'));
      a.backend.offline = false;
      await b.app.flushNow(force: true);
      final left = b.app.expenses.where((e) => e.clientUid == 'dup').single;
      expect(left.syncError, contains('sipariş'));
      expect(a.backend.expensesOf(_email), hasLength(1));
    });
  });

  group('readDigitalReceipt: .eml / .html', () {
    late Directory dir;
    late FakePdfReader reader;
    late PdfReader saved;
    late Harness h;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('fissio_digital_');
      saved = pdfReader;
      reader = FakePdfReader();
      pdfReader = reader;
      h = await _signedIn(syncOn: false); // yerel ayrıştırma (deterministik)
    });
    tearDown(() {
      pdfReader = saved;
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    String write(String name, String content) {
      final f = File('${dir.path}/$name')..writeAsBytesSync(utf8.encode(content));
      return f.path;
    }

    const orderHtml = '<html><body><div style="display:none">özet</div><table>'
        '<tr><td>Restoran</td><td>Köşebaşı Döner</td></tr><tr><td>Sipariş No</td><td>YS-4F7A91C2</td></tr>'
        '<tr><td>Sipariş Tarihi</td><td>14.11.2026 13:05</td></tr>'
        '<tr><td>1 x Tavuk Döner Porsiyon</td><td>185,00 TL</td></tr><tr><td>1 x Ayran</td><td>25,00 TL</td></tr>'
        '<tr><td>Toplam</td><td>210,00 TL</td></tr></table><p>Abonelikten çık</p></body></html>';

    test('.html: temizlenir, sipariş kodu ve motor "email"', () async {
      final d = await h.app.readDigitalReceipt(write('ozet.html', orderHtml));
      expect(d.orderId, 'YS-4F7A91C2');
      expect(d.documentNo, isNull);
      expect(d.ocrEngine, kStoredEmail);
      expect(d.savedAmount, 210);
      expect(d.date, DateTime(2026, 11, 14));
      expect(d.toRequestBody()['order_id'], 'YS-4F7A91C2');
      expect(reader.paths, isEmpty, reason: 'PDF okuyucu kullanılmaz');
    });

    test('.eml (HTML gövde, İlet önsözü, QP utf-8): önsöz atılır; işletme/tarih önsözden okunmaz', () async {
      final eml = 'From: Ahmet <ahmet@gmail.com>\nTo: x@fis.fissio.app\nSubject: =?UTF-8?Q?Fwd:_Sipari=C5=9F?=\nContent-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: base64\n\n'
          '${base64.encode(utf8.encode('<div>---------- Forwarded message ---------<br>From: Yemeksepeti &lt;info@ys.com&gt;<br>Date: Sat, 14 Nov 2026<br>Subject: Siparişiniz<br>To: &lt;ahmet@gmail.com&gt;</div>$orderHtml'))}\n';
      final d = await h.app.readDigitalReceipt(write('fwd.eml', eml));
      expect(d.orderId, 'YS-4F7A91C2');
      expect(d.merchant.toLowerCase(), isNot(contains('forwarded')));
      expect(d.merchant.toLowerCase(), isNot(contains('yemeksepeti')), reason: 'önsöz başlığı işletme sayılmaz');
      expect(d.savedAmount, 210);
      expect(d.note, 'E-posta: Fwd: Sipariş');
      expect(d.ocrEngine, kStoredEmail);
    });

    test('.eml PDF eki: metin katmanı varsa PDF hattı (motor "pdf"), HTML gövdeye bakılmaz', () async {
      reader.textPages = ['ACME GIDA TICARET A.S.\nVKN: 1750051846\ne-Arşiv Fatura\nETTN: $_ettn1\nFatura No: GIB2026000000123\nFatura Tarihi: 05-11-2026\nSüt 1 L 2 Adet 30,00 TL 60,00 TL\nÖdenecek Tutar 60,00 TL'];
      final pdf = base64.encode(Uint8List.fromList(utf8.encode('%PDF-1.4 fake')));
      final eml = 'From: a@b.com\nTo: x@fis.fissio.app\nSubject: Fatura\nContent-Type: multipart/mixed; boundary="m"\n\n'
          '--m\nContent-Type: text/html\n\n<p>Faturanız ektedir. Toplam 1,00</p>\n'
          '--m\nContent-Type: application/pdf; name="fatura.pdf"\nContent-Disposition: attachment; filename="fatura.pdf"\nContent-Transfer-Encoding: base64\n\n$pdf\n--m--\n';
      final d = await h.app.readDigitalReceipt(write('pdfli.eml', eml));
      expect(d.ocrEngine, kStoredPdf);
      expect(d.documentNo, _ettn1);
      expect(reader.paths, hasLength(1));
      expect(File(reader.paths.single).existsSync(), isFalse, reason: 'geçici PDF silinir');
    });

    test('.eml: PDF okunamıyorsa HTML gövdeye düşer', () async {
      reader.failure = PdfReadException('bozuk');
      final pdf = base64.encode(Uint8List.fromList(utf8.encode('%PDF-1.4 fake')));
      final eml = 'From: a@b.com\nTo: x@fis.fissio.app\nSubject: Sipariş\nContent-Type: multipart/mixed; boundary="m"\n\n'
          '--m\nContent-Type: text/html; charset=utf-8\n\n$orderHtml\n'
          '--m\nContent-Type: application/pdf; name="x.pdf"\nContent-Transfer-Encoding: base64\n\n$pdf\n--m--\n';
      final d = await h.app.readDigitalReceipt(write('bozuk.eml', eml));
      expect(d.orderId, 'YS-4F7A91C2');
      expect(d.ocrEngine, kStoredEmail);
    });

    test('mükerrer: aynı sipariş zaten kayıtlıysa okuma 409 duplicate_order verir; resmi fatura ise ön özete birleşecek (hata değil)', () async {
      final first = await h.app.readDigitalReceipt(write('a.html', orderHtml));
      await h.app.saveDraft(first);
      await expectLater(
        h.app.readDigitalReceipt(write('b.html', orderHtml)),
        throwsA(isA<ApiException>().having((e) => e.duplicateOrder, 'duplicateOrder', isTrue)),
      );
      final official = orderHtml.replaceAll('</table>', '<tr><td>ETTN</td><td>$_ettn1</td></tr></table>').replaceAll('210,00 TL</td></tr></table>', '210,00 TL</td></tr></table>');
      final d = await h.app.readDigitalReceipt(write('c.html', official));
      expect(d.documentNo, _ettn1, reason: 'resmi belge okunur; kayıtta ön özete birleşir');
      final res = await h.app.saveDraft(d);
      expect(res.merged, isTrue);
      expect(h.app.expenses, hasLength(1));
    });

    test('okunamayan / boş dosya anlaşılır hata verir', () async {
      await expectLater(h.app.readDigitalReceipt(write('bos.html', '<html><body></body></html>')), throwsA(isA<ApiException>()));
      await expectLater(h.app.readDigitalReceipt('${dir.path}/yok.eml'), throwsA(isA<ApiException>()));
      await expectLater(h.app.readDigitalReceipt(write('kotu.eml', 'bu bir e-posta değil')), throwsA(isA<ApiException>()));
    });
  });

  group('JSON yedek', () {
    test('order_id dışa/içe aktarılır, has_official_invoice document_no\'dan türer; eski yedek (alansız) yüklenir', () async {
      final h = await _signedIn(syncOn: false);
      await h.app.saveDraft(_draft('Yemeksepeti', 210, orderId: 'YS-3', uid: 'x1'));
      final json = exportJson(buildBackup(h.app.profiles, h.app.allExpenses));
      expect(json, contains('"order_id": "YS-3"'));
      expect(json, isNot(contains('has_official_invoice')), reason: 'ön özette resmi bayrak yazılmaz');

      await h.app.saveDraft(_draft('Restoran', 212.5, orderId: 'YS-3', documentNo: _ettn1, uid: 'x2')); // birleşir
      final json2 = exportJson(buildBackup(h.app.profiles, h.app.allExpenses));
      expect(json2, contains('"has_official_invoice": true'));
      final back = parseBackup(json2);
      final be = back.profiles.expand((p) => p.expenses).single;
      expect(be.orderId, 'YS-3');
      expect(be.documentNo, _ettn1);

      // Eski yedek: alanlar yok → null; geçersiz order_id yok sayılır.
      const old = '{"format":"fissio-backup","version":1,"exported_at":"2026-01-01T00:00:00Z","profiles":[{"uid":"p1","name":"Kişisel","expenses":['
          '{"uid":"e1","date":"2026-05-12","merchant":"BIM","amount":50,"category":"Market / Gıda","note":"","items":[]},'
          '{"uid":"e2","date":"2026-05-13","merchant":"A","amount":10,"category":"Market / Gıda","note":"","order_id":"x","items":[]}]}]}';
      final parsed = parseBackup(old).profiles.single.expenses;
      expect(parsed[0].orderId, isNull);
      expect(parsed[1].orderId, isNull, reason: 'geçersiz biçim');
    });

    test('içe aktarma: aynı belge / aynı sipariş (+tür) zaten varsa atlanır', () async {
      final h = await _signedIn(syncOn: false);
      await h.app.saveDraft(_draft('Restoran', 212.5, orderId: 'YS-4', documentNo: _ettn1, uid: 'a'));
      final data = parseBackup(
        '{"format":"fissio-backup","version":1,"exported_at":"2026-01-01T00:00:00Z","profiles":[{"uid":"p1","name":"Kişisel","expenses":['
        '{"uid":"n1","date":"2026-11-14","merchant":"Başka ad","amount":99,"category":"Market / Gıda","note":"","document_no":"$_ettn1","items":[]},'
        '{"uid":"n2","date":"2026-11-14","merchant":"Y","amount":98,"category":"Market / Gıda","note":"","order_id":"YS-4","document_no":"$_ettn2","items":[]},'
        '{"uid":"n3","date":"2026-11-14","merchant":"Z","amount":97,"category":"Market / Gıda","note":"","order_id":"YS-5","items":[]}]}]}',
      );
      final summary = await importBackup(h.app, data);
      expect(summary.imported, 1, reason: 'yalnızca n3 yeni');
      expect(summary.skipped, 2);
    });
  });

  test('Expense JSON: order_id okunur, has_official_invoice document_no\'dan türer, merged yalnızca POST cevabında', () {
    final e = Expense.fromJson({
      'id': 1,
      'merchant': 'M',
      'amount': 10,
      'date': '2026-11-14',
      'category_id': 1,
      'items': [],
      'order_id': 'YS-1',
      'document_no': _ettn1,
      'status': 'merged',
    });
    expect(e.orderId, 'YS-1');
    expect(e.hasOfficialInvoice, isTrue);
    expect(e.merged, isTrue);
    final round = Expense.fromLocalJson(e.toLocalJson());
    expect(round.orderId, 'YS-1');
    expect(round.merged, isFalse, reason: 'saklanmaz');
    expect(round.copyWith(merchant: 'N').orderId, 'YS-1');
  });
}
