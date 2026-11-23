package receiptparse

// CategorizeStructured, metinden ayrıştırılmamış ama yapılandırılmış gelen fişleri (UBL-TR e-Fatura XML'i, HTML
// tablo kalemleri) aynı kategori motorundan geçirir: işletme adı başlık sayılır, kalem adları kalem sözlüğüne girer.
// Girdi kalemlerinin Name/Amount alanları korunur; kategori alanları doldurulur.
func CategorizeStructured(merchant string, amount float64, items []Item, date *string, cats []Category, opts ParseOptions) ParseResult {
	cats = enrichCats(cats)
	ci := newCatIndex(cats)
	header := []string{merchant}
	res := ParseResult{Merchant: merchant, Amount: &amount, Date: date, CategoryName: fallbackCategory}
	res.Items = append([]Item(nil), items...)
	m := ci.classifyMerchant(cats, header, header, merchant, opts.Rules)
	res.CategoryID, res.CategoryName, res.Confidence.Category = m.ID, m.Name, m.Conf
	ci.applyCategories(&res, m, opts.Rules)
	return res
}
