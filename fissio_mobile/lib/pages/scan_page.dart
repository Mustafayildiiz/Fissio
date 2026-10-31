import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets.dart';
import 'receipt_form_page.dart';

/// Tara ekranı arayüzü. Kamera ve ML Kit OCR bir sonraki fazda (Faz 5) bağlanacak.
class ScanPage extends StatelessWidget {
  const ScanPage({super.key});

  void _soon(BuildContext context) =>
      showMessage(context, 'Kamera ve OCR bir sonraki fazda (Faz 5) eklenecek.');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const BackTitle('Fiş Oluştur'),
            ModeSwitch(
              scanActive: true,
              onChange: (scan) {
                if (!scan) {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const ReceiptFormPage()),
                  );
                }
              },
            ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.photo_camera, size: 90, color: AppColors.secondaryText),
                      const SizedBox(height: 18),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          'Fişin fotoğrafını çekmek için kamera erişimi gerekmektedir',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      ),
                      const SizedBox(height: 16),
                      PrimaryButton(
                        label: 'İzin ver',
                        compact: true,
                        onPressed: () => _soon(context),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    tooltip: 'Galeri',
                    onPressed: () => _soon(context),
                    icon: const Icon(Icons.image_outlined, size: 32, color: AppColors.secondaryText),
                  ),
                  InkWell(
                    onTap: () => _soon(context),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: const BoxDecoration(
                        color: AppColors.light,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Manuel giriş',
                    onPressed: () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const ReceiptFormPage()),
                    ),
                    icon: const Icon(Icons.receipt_long, size: 32, color: AppColors.secondaryText),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

