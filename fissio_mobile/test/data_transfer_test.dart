import 'dart:convert';

import 'package:fissio_mobile/data/data_transfer.dart';
import 'package:fissio_mobile/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

BackupData _sample() => BackupData(1, DateTime.utc(2026, 5, 20), [
  BackupProfile('p-1', 'Kişisel', [
    BackupExpense(
      uid: 'e-1',
      date: DateTime(2026, 5, 12),
      merchant: 'BIM; "Şube" 1',
      amount: 1234.5,
      category: 'Market / Gıda',
      note: 'ilk\nsatır',
      items: [const BackupItem('SÜT 1L', 34.5, 'Market / Gıda'), const BackupItem('EKMEK', 1200, '')],
    ),
    BackupExpense(
      uid: 'e-2',
      date: DateTime(2026, 5, 13),
      merchant: '=HYPERLINK("x")',
      amount: 20,
      category: 'Diğer',
      note: '',
      items: const [], // kalemsiz fiş CSV'de kaybolmamalı
    ),
  ]),
  BackupProfile('p-2', 'Ev', [
    BackupExpense(uid: 'e-3', date: DateTime(2026, 5, 14), merchant: 'Migros', amount: 99.99, category: 'Market / Gıda', note: '', items: const []),
  ]),
]);

void main() {
  group('JSON', () {
    test('dışa aktar -> içe aktar tam döngü', () {
      final text = exportJson(_sample());
      final j = jsonDecode(text) as Map<String, dynamic>;
      expect(j['format'], 'fissio-backup');
      expect(j['version'], 1);
      final back = parseBackup(text);
      expect(back.errors, isEmpty);
      expect(back.profiles.map((p) => p.name), ['Kişisel', 'Ev']);
      expect(back.expenseCount, 3);
      final e = back.profiles.first.expenses.first;
      expect(e.uid, 'e-1');
      expect(e.merchant, 'BIM; "Şube" 1');
      expect(e.amount, 1234.5);
      expect(e.items.map((i) => i.amount), [34.5, 1200]);
      expect(e.note, 'ilk\nsatır');
    });

    test('biçim doğrulaması: yanlış dosya, bozuk JSON, desteklenmeyen sürüm', () {
      expect(() => parseBackup('{"foo":1}'), throwsA(isA<FormatException>().having((e) => e.message, 'm', contains('Fissio yedeği değil'))));
      expect(() => parseBackup('{bozuk'), throwsA(isA<FormatException>()));
      expect(() => parseBackup(''), throwsA(isA<FormatException>()));
      expect(
        () => parseBackup('{"format":"fissio-backup","version":99,"profiles":[]}'),
        throwsA(isA<FormatException>().having((e) => e.message, 'm', contains('sürüm'))),
      );
      expect(() => parseBackup('{"format":"fissio-backup","version":1}'), throwsA(isA<FormatException>()));
    });

    test('geçersiz fişler atlanır ve raporlanır, geçerliler yüklenir', () {
      final text = jsonEncode({
        'format': 'fissio-backup',
        'version': 1,
        'profiles': [
          {
            'uid': 'p',
            'name': 'Kişisel',
            'expenses': [
              {'date': '2026-05-01', 'merchant': 'OK', 'amount': 10, 'items': []},
              {'date': '2026-13-45', 'merchant': 'Bozuk tarih', 'amount': 10},
              {'date': '2026-05-01', 'merchant': 'Negatif', 'amount': -5},
              {'date': '2026-05-01', 'merchant': 'Kalem hatalı', 'amount': 5, 'items': [{'name': 'x', 'amount': 'abc'}]},
              'bir string',
            ],
          },
          {'name': '', 'expenses': []},
        ],
      });
      final b = parseBackup(text);
      expect(b.expenseCount, 1);
      expect(b.errors, hasLength(5));
    });
  });

  group('CSV', () {
    test('Excel için BOM + noktalı virgül; kalemsiz fiş tek satır olarak yazılır', () {
      final csv = exportCsv(_sample());
      expect(csv.startsWith('﻿'), isTrue);
      final lines = csv.substring(1).trim().split('\r\n');
      expect(lines.first.split(';'), csvHeader);
      // e-1: 2 kalem, e-2: kalemsiz (1 satır), e-3: kalemsiz (1 satır)
      expect(lines.length - 1, 4);
      expect(csv, contains('1234,50'), reason: 'Türkçe Excel için ondalık virgül');
    });

    test('dışa aktar -> içe aktar: kalemler fişe geri gruplanır, tırnak/satır sonu/formül korunur', () {
      final back = parseBackup(exportCsv(_sample()));
      expect(back.errors, isEmpty);
      expect(back.expenseCount, 3);
      final kisisel = back.profiles.firstWhere((p) => p.name == 'Kişisel');
      expect(kisisel.uid, 'p-1');
      final e1 = kisisel.expenses.firstWhere((e) => e.uid == 'e-1');
      expect(e1.items, hasLength(2));
      expect(e1.merchant, 'BIM; "Şube" 1');
      expect(e1.note, 'ilk\nsatır');
      expect(e1.amount, 1234.5);
      expect(e1.items.last.amount, 1200);
      final e2 = kisisel.expenses.firstWhere((e) => e.uid == 'e-2');
      expect(e2.merchant, '=HYPERLINK("x")', reason: 'formül koruması geri alınır');
      expect(e2.items, isEmpty);
    });

    test('formül enjeksiyonu: = + - @ ile başlayan metinler dışa aktarımda etkisizleştirilir', () {
      expect(exportCsv(_sample()), contains("'=HYPERLINK"));
    });

    test('ayraç otomatik algılanır (virgül / sekme) ve ondalık , veya . kabul edilir', () {
      const commaCsv = 'tarih,isyeri,toplam\n2026-05-01,A,"12,50"\n2026-05-02,B,12.5\n12.05.2026,C,"1.234,56"\n';
      final b = parseBackup(commaCsv);
      expect(b.errors, isEmpty);
      final amounts = b.profiles.single.expenses.map((e) => e.amount).toList();
      expect(amounts, [12.5, 12.5, 1234.56]);
      expect(b.profiles.single.expenses.last.date, DateTime(2026, 5, 12));
      final tab = parseBackup('tarih\tisyeri\ttoplam\n01.05.2026\tX\t10,00\n');
      expect(tab.expenseCount, 1);
    });

    test('bozuk CSV: tanınmayan başlık, kapanmamış tırnak, geçersiz satırlar', () {
      expect(() => parseBackup('a;b;c\n1;2;3'), throwsA(isA<FormatException>()));
      expect(() => parseBackup('tarih;isyeri;toplam\n2026-05-01;"A;10'), throwsA(isA<FormatException>()));
      final b = parseBackup('tarih;isyeri;toplam\n2026-05-01;OK;10\nyarin;Kotu;10\n2026-05-02;Eksi;-3\n');
      expect(b.expenseCount, 1);
      expect(b.errors, hasLength(2));
      expect(b.errors.first, contains('Satır 3'));
    });
  });

  group('tutar ve tarih okuma', () {
    test('parseAmount', () {
      expect(parseAmount('12,50'), 12.5);
      expect(parseAmount('12.50'), 12.5);
      expect(parseAmount('1.234,50'), 1234.5);
      expect(parseAmount('1,234.50'), 1234.5);
      expect(parseAmount('1.234'), 1234);
      expect(parseAmount('12,50 ₺'), 12.5);
      expect(parseAmount('abc'), isNull);
      expect(parseAmount(''), isNull);
    });
    test('parseDate', () {
      expect(parseDate('2026-05-12'), DateTime(2026, 5, 12));
      expect(parseDate('12.05.2026'), DateTime(2026, 5, 12));
      expect(parseDate('12/05/2026'), DateTime(2026, 5, 12));
      expect(parseDate('2026-02-31'), isNull);
      expect(parseDate('x'), isNull);
    });
  });

  group('uygulamaya içe aktarma (mükerrer önleme)', () {
    late Harness h;
    setUp(() => h = Harness());

    Future<void> seed() async {
      await h.signIn('ali@x.co');
      await h.app.createProfile('Ev');
      final ev = h.app.activeProfile!;
      final kisisel = h.app.profiles.first;
      await h.app.selectProfile(kisisel);
      await h.app.saveDraft(ReceiptDraft(merchant: 'BIM', categoryId: 1, items: [ExpenseItem('SÜT', 10, categoryId: 1)]));
      await h.app.selectProfile(ev);
      await h.app.saveDraft(ReceiptDraft(merchant: 'Migros', categoryId: 2, items: [ExpenseItem('Yemek', 50)]));
    }

    test('dışa aktarılan JSON iki kez içe aktarılsa da mükerrer kayıt oluşmaz', () async {
      await seed();
      final json = exportJson(buildBackup(h.app.profiles, h.app.allExpenses));
      expect(parseBackup(json).expenseCount, 2);

      // Aynı hesaba geri yükle: hepsi zaten var.
      final r1 = await importBackup(h.app, parseBackup(json));
      expect(r1.imported, 0);
      expect(r1.skipped, 2);
      expect(h.backend.expensesOf('ali@x.co'), hasLength(2));

      // Başka (temiz) bir cihaz/hesaba yükle: eklenir, ikinci kez eklenmez.
      final h2 = Harness();
      await h2.signIn('yeni@x.co');
      final first = await importBackup(h2.app, parseBackup(json));
      expect(first.imported, 2);
      expect(first.profilesCreated, greaterThanOrEqualTo(1));
      await h2.settle(100);
      final second = await importBackup(h2.app, parseBackup(json));
      expect(second.imported, 0);
      expect(second.skipped, 2);
      await h2.settle(100);
      expect(h2.backend.expensesOf('yeni@x.co'), hasLength(2), reason: 'sunucuda da mükerrer yok');
      expect(h2.app.allExpenses, hasLength(2));
    });

    test('CSV iki kez içe aktarma: mükerrer yok; uid\'siz dosyada parmak izi ile eşleşir', () async {
      await seed();
      final csv = exportCsv(buildBackup(h.app.profiles, h.app.allExpenses));
      final r = await importBackup(h.app, parseBackup(csv));
      expect(r.imported, 0);
      expect(r.skipped, 2);

      // uid sütunlarını sil (başka kaynaktan gelen dosya): parmak izi aynı fişi tanır.
      final stripped = csv.split('\r\n').map((l) {
        final c = l.split(';');
        if (c.length > 3) c[2] = '';
        return c.join(';');
      }).join('\r\n');
      final r2 = await importBackup(h.app, parseBackup(stripped));
      expect(r2.imported, 0, reason: 'parmak izi (profil+tarih+işyeri+tutar+kalemler) eşleşti');
      expect(r2.skipped, 2);
      await h.settle(50);
      expect(h.backend.expensesOf('ali@x.co'), hasLength(2));
    });

    test('uid\'siz dosya iki kez yüklenince türetilmiş uid ile mükerrer oluşmaz', () async {
      await h.signIn('ali@x.co');
      const csv = 'profil;tarih;isyeri;toplam\nKişisel;2026-05-01;Sahaf;45,00\nKişisel;2026-05-02;Kırtasiye;12,00\n';
      final a = await importBackup(h.app, parseBackup(csv));
      expect(a.imported, 2);
      await h.settle(100);
      final b = await importBackup(h.app, parseBackup(csv));
      expect(b.imported, 0);
      expect(b.skipped, 2);
      await h.settle(100);
      expect(h.backend.expensesOf('ali@x.co'), hasLength(2));
      // "Kişisel" mevcut profile yazıldı, yeni profil açılmadı.
      expect(h.app.profiles.where((p) => p.name == 'Kişisel'), hasLength(1));
    });

    test('senkron kapalıyken içe aktarılan veri yalnızca cihazda kalır, sunucuya gitmez', () async {
      await h.signIn('ali@x.co');
      await h.app.setSyncEnabled(false);
      h.backend.log.clear();
      const csv = 'tarih;isyeri;toplam\n2026-05-01;Gizli;45,00\n';
      final r = await importBackup(h.app, parseBackup(csv));
      expect(r.imported, 1);
      await h.settle(50);
      expect(h.backend.writes, isEmpty);
      expect(h.app.localOnlyCount, greaterThanOrEqualTo(1));
      // Açınca yüklenir.
      await h.app.setSyncEnabled(true);
      await h.settle(100);
      expect(h.backend.expensesOf('ali@x.co').map((e) => e['merchant']), ['Gizli']);
    });

    test('kategori adı eşlenir, bilinmeyen kategori "Diğer" olur', () async {
      await h.signIn('ali@x.co');
      const csv = 'tarih;isyeri;toplam;kategori\n2026-05-01;A;10;Restoran / Kafe\n2026-05-02;B;10;Uydurma Kategori\n';
      await importBackup(h.app, parseBackup(csv));
      final byMerchant = {for (final e in h.app.allExpenses) e.merchant: e.categoryName};
      expect(byMerchant['A'], 'Restoran / Kafe');
      expect(byMerchant['B'], 'Diğer');
    });
  });
}
