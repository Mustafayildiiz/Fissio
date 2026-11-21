package digital

import "testing"

func TestHTMLTableItemsYemeksepetiStyle(t *testing.T) {
	src := `<html><body><table><tr><td>
	<table>
	  <tr><th>Ürün</th><th>Adet</th><th>Fiyat</th></tr>
	  <tr><td>Tavuk Döner Porsiyon</td><td>2</td><td>92,50 TL</td><td>185,00 TL</td></tr>
	  <tr><td>Ayran</td><td>1</td><td>15,00 TL</td></tr>
	  <tr><td>Teslimat Ücreti</td><td>12,90 TL</td></tr>
	  <tr><td>Poşet</td><td>2,00 TL</td></tr>
	  <tr><td>Ara Toplam</td><td>214,90 TL</td></tr>
	  <tr><td>KDV (%10)</td><td>19,54 TL</td></tr>
	  <tr><td>İndirim</td><td>10,00 TL</td></tr>
	  <tr><td>Genel Toplam</td><td>214,90 TL</td></tr>
	</table></td></tr></table></body></html>`
	got := HTMLTableItems(src)
	want := []TableItem{
		{"Tavuk Döner Porsiyon", 2, 18500},
		{"Ayran", 1, 1500},
		{"Teslimat Ücreti", 1, 1290},
		{"Poşet", 1, 200},
	}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("item %d = %+v, want %+v", i, got[i], want[i])
		}
	}
	if got[0].DisplayName() != "2 x Tavuk Döner Porsiyon" || got[1].DisplayName() != "Ayran" {
		t.Errorf("display: %q %q", got[0].DisplayName(), got[1].DisplayName())
	}
}

func TestHTMLTableItemsQtyForms(t *testing.T) {
	src := `<table>
	  <tr><td>3 x Lahmacun</td><td>90,00 TL</td></tr>
	  <tr><td>2x Kola</td><td>40,00 ₺</td></tr>
	  <tr><td>1</td><td>Künefe</td><td>1.250,50 TL</td></tr>
	  <tr><td>KARTON SÜT</td><td>30,00 TL</td></tr>
	  <tr><td>Toplam</td><td>1.410,50 TL</td></tr>
	  <tr><td>Toplam Tutar:</td><td>1.410,50 TL</td></tr>
	</table>`
	got := HTMLTableItems(src)
	want := []TableItem{{"Lahmacun", 3, 9000}, {"Kola", 2, 4000}, {"Künefe", 1, 125050}, {"KARTON SÜT", 1, 3000}}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("item %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

func TestHTMLTableItemsIgnoresHiddenAndNonMoney(t *testing.T) {
	src := `<table>
	  <tr style="display:none"><td>Gizli</td><td>5,00 TL</td></tr>
	  <tr><td>Sipariş No</td><td>ABC123</td></tr>
	  <tr><td>Tutar yok</td><td>-</td></tr>
	  <tr><td>Pizza</td><td>99,90 TL</td></tr>
	</table>`
	got := HTMLTableItems(src)
	if len(got) != 1 || got[0].Name != "Pizza" || got[0].AmountCents != 9990 {
		t.Fatalf("got %+v", got)
	}
}
