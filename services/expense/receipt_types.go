package main

import (
	"math"

	"fissio/expense/internal/receiptparse"
)

// Fis ayristirma hatti internal/receiptparse paketindedir (saf, DB'siz). Kalem ve kategori tipleri
// istek/yanit JSON'u, JSONB saklama ve ayristirma ciktisinda ortaktir; takma adlar (alias) ayni tipi
// package main'de eski adlariyla kullanir (JSON bicimi degismez).
type (
	// Category kategorizasyon motorunun girdisi ve /categories yanitinin elemanidir.
	Category = receiptparse.Category
	// expenseItem fisin kalemidir (bkz. receiptparse.Item).
	expenseItem = receiptparse.Item
)

// round2 tutari 2 ondalik haneye yuvarlar (receiptparse ile ayni kural).
func round2(v float64) float64 { return math.Round(v*100) / 100 }
