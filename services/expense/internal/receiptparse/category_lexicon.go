package receiptparse

import "strings"

// catKey, kategorinin ADINDAN bagimsiz kararli kimligidir. Sozluk bu anahtarla tutulur; veritabanindaki
// kategori adi ("Market" ya da "Market / Gıda") categoryKeyOf ile anahtara cevrilir. Boylece
// taksonomi yeniden adlandirilsa da (ya da eski kurulumlar eski adlarla kalsa da) motor calisir.
type catKey string

const (
	keyMarket      catKey = "market"
	keyFuel        catKey = "fuel" // Akaryakit / Ulasim
	keyFood        catKey = "food" // Restoran / Kafe
	keyHealth      catKey = "health"
	keyClothes     catKey = "clothes"
	keyElectronics catKey = "electronics"
	keyBills       catKey = "bills"
	keyHome        catKey = "home"
	keyPersonal    catKey = "personal"
	keyFun         catKey = "fun"
	keyOther       catKey = "other"
)

// lexiconPriority: esit puanli kalem eslesmelerinde (ve baglam yoksa) tercih sirasi.
var lexiconPriority = []catKey{keyMarket, keyFood, keyHealth, keyFuel, keyHome, keyPersonal, keyClothes, keyElectronics, keyBills, keyFun}

// categoryKeyOf kategori adini sabit anahtara cevirir. Bilinmeyen ad keyOther'dir (ozel kategori).
func categoryKeyOf(name string) catKey {
	f := FoldTR(name)
	switch {
	case strings.HasPrefix(f, "market"):
		return keyMarket
	case strings.HasPrefix(f, "akaryakit"), strings.HasPrefix(f, "ulasim"):
		return keyFuel
	case strings.HasPrefix(f, "restoran"), strings.HasPrefix(f, "kafe"), strings.HasPrefix(f, "cafe"):
		return keyFood
	case strings.HasPrefix(f, "saglik"):
		return keyHealth
	case strings.HasPrefix(f, "giyim"):
		return keyClothes
	case strings.HasPrefix(f, "elektronik"):
		return keyElectronics
	case strings.HasPrefix(f, "fatura"):
		return keyBills
	case strings.HasPrefix(f, "ev ") || strings.HasPrefix(f, "ev/") || f == "ev":
		return keyHome
	case strings.HasPrefix(f, "kisisel"):
		return keyPersonal
	case strings.HasPrefix(f, "eglence"):
		return keyFun
	}
	return keyOther
}

type lexEntry struct {
	brands []string // isletme adi / marka (fis basliginda aranir)
	items  []string // urun kok ve ifadeleri (kalem adinda aranir)
}

// terms virgulle ayrilmis listeyi FoldTR'den gecirip dilimler.
func terms(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(FoldTR(p)); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// lexicon: Turkiye'deki gunluk harcama aliskanliklarina gore marka ve urun sozlugu.
// Kelimeler FoldTR formunda (kucuk harf, ASCII) tutulur. Kisa (<4 harf) kelimeler yalnizca tam
// eslesir; uzunlar onek (ek toleransi) ve bulanik eslesir. "cay", "kola", "su" gibi baglama gore
// degisen urunler birden cok kategoride yer alir; isletme kategorisi kazanir (bkz. classifyItem).
var lexicon = map[catKey]lexEntry{
	keyMarket: {
		brands: terms("bim, a101, migros, sok, carrefour, carrefoursa, macro, macrocenter, market, supermarket, bakkal, manav, kasap, hakmar, kiler, gimsa, happy center, tarim kredi, file market, onur market, ekomini"),
		items:  terms("sut, ekmek, peynir, beyaz peynir, kasar, lor, yogurt, ayran, yumurta, tereyag, margarin, zeytin, zeytinyagi, aycicek, yag, un, seker, tuz, mercimek, nohut, fasulye, pirinc, bulgur, makarna, spagetti, spageti, eriste, salca, domates, biber, patates, sogan, sarimsak, salatalik, havuc, limon, portakal, elma, muz, armut, uzum, cilek, karpuz, kavun, mandalina, marul, maydanoz, dereotu, ispanak, kabak, patlican, tavuk, pilic, kiyma, dana, kuzu, sucuk, salam, sosis, jambon, balik, hamsi, somon, konserve, recel, bal, tahin, pekmez, findik, fistik, ceviz, badem, kuruyemis, cikolata, biskuvi, gofret, kraker, cips, kek, popkek, sakiz, helva, lokum, dondurma, su, maden suyu, madensuyu, nugget, soda, gazoz, kola, cola, meyve suyu, icecek, cay, kahve, nescafe, misir, corn flakes, kaymak, krema, marmelat, ketcap, mayonez, hardal, sirke, baharat, nane, bira, sarap, raki, ekmek, simit, pogaca, yufka, galeta, bebek bisküvisi, sebze, meyve, kofte, hazir corba, corba, pudra seker, vanilya, kabartma tozu, maya, irmik, nisasta, tarhana, tursu, kornison, humus, dolma"),
	},
	keyFuel: {
		brands: terms("opet, shell, bp, petrol ofisi, aytemiz, total, totalenergies, lukoil, alpet, moil, kadoil, sunpet, petrol, akaryakit, taksi, bitaksi, uber, otopark, ispark, otobus, istanbulkart, hgs, ogs, marti, pegasus, thy, turk hava yollari, havaist, iett, metro istanbul, marmaray, ido, bsfd"),
		items:  terms("kursunsuz, benzin, motorin, dizel, euro diesel, diesel, lpg, v power, adblue, otopark, taksi, hgs, ogs, yakit, akaryakit, otoyol, kopru, gecis ucreti, istanbulkart, jeton"),
	},
	keyFood: {
		brands: terms("starbucks, mcdonald, mcdonalds, burger king, kfc, dominos, domino, popeyes, simit sarayi, kahve dunyasi, gloria jeans, caffe nero, tavuk dunyasi, baydoner, kafe, cafe, restoran, restaurant, lokanta, kebap, pizza, burger, doner, kofteci, ocakbasi, pastane, pastanesi, kafeterya, bufe, cigkofte, balikci, meyhane, kahvalti"),
		items:  terms("adana, urfa kebap, iskender, lahmacun, pide, kebap, doner, kofte, tantuni, corba, mercimek corbasi, servis, latte, espresso, cappuccino, americano, mocha, filtre kahve, frappe, cheesecake, tiramisu, sufle, baklava, kunefe, ayran, limonata, turk kahvesi, cay, kola, cola, su, gazoz, tatli, menu, porsiyon, tost, hamburger, cheeseburger, patates kizartmasi, nugget, pizza, sinitli, kahve, salata, tavuk sis, et doner, kanat, wrap, makarna, bira, pilav, ekmek arasi, sandvic, sandwich, cikolata sicak, sicak cikolata, hizmet bedeli, kuver, bahsis"),
	},
	keyHealth: {
		brands: terms("eczane, eczanesi, eczanem, hastane, hastanesi, klinik, poliklinik, saglik, dis hekimi, optik, laboratuvar, tip merkezi, medikal"),
		items:  terms("surup, tablet, kapsul, draje, merhem, agri kesici, parasetamol, aspirin, vitamin, serum fizyolojik, maske, dezenfektan, pansuman, gozluk, termometre, antibiyotik, ibuprofen, burun spreyi, damla, ilac, recete, katilim payi, muayene, krem, sprey, enjektor, flaster, tansiyon, oksijen, probiyotik, omega, magnezyum, zinc, cinko, kolonya"),
	},
	keyClothes: {
		brands: terms("lc waikiki, lcw, koton, defacto, zara, mavi, boyner, bershka, stradivarius, pull bear, network, kigili, flo, sarar, vakko, beymen, ayakkabi, giyim, tekstil, butik, h m, hm, nike, adidas, puma, colins, jack jones, ipekyol"),
		items:  terms("tisort, gomlek, pantolon, kot, elbise, etek, mont, kaban, ceket, hirka, kazak, sweatshirt, ayakkabi, bot, cizme, terlik, sandalet, corap, ic camasir, atlet, pijama, sort, bere, atki, eldiven, kemer, canta, cuzdan, bluz, tayt, mayo, bikini, spor ayakkabi, sneaker, yelek, esofman"),
	},
	keyElectronics: {
		brands: terms("teknosa, mediamarkt, media markt, vatan, vatan bilgisayar, arcelik, vestel, apple, samsung, xiaomi, bilgisayar, elektronik, gsm, hepsiburada, n11, bimeks"),
		items:  terms("kablo, sarj, sarj aleti, adaptor, kulaklik, hoparlor, mouse, klavye, usb, bellek, powerbank, telefon kilifi, kilif, ekran koruyucu, hdmi, laptop, ipad, hafiza karti, flash disk, priz, uzatma kablosu, telefon, monitor, yazici, toner, kartus, router, modem, televizyon, tv, kamera, oyun konsolu, airpods, saat, pil, batarya"),
	},
	keyBills: {
		brands: terms("turkcell, vodafone, turk telekom, turknet, superonline, enerjisa, igdas, iski, aski, bedas, ayedas, tedas, baskentgaz, netflix, spotify, youtube, disney, amazon prime, exxen, blutv, tod, digiturk, d smart, telekom"),
		items:  terms("fatura, abonelik, aidat, faturasi, internet, dogalgaz, elektrik, su faturasi, tahsilat, uyelik, kontor, paket, tarife, yukleme, gsm hatti, tv paketi"),
	},
	keyHome: {
		brands: terms("koctas, ikea, bauhaus, tekzen, evidea, english home, madame coco, karaca, emsan, yatas, bellona, istikbal, dogtas, mondi, hirdavat, nalbur, yapi market, mobilya, dekorasyon, ev tekstili, ozdilek home, jysk"),
		items:  terms("deterjan, camasir suyu, camasir yumusaticisi, yumusatici, bulasik, bulasik deterjani, temizlik, cop torbasi, cop poseti, pecete, kagit havlu, tuvalet kagidi, havlu, carsaf, nevresim, yastik, battaniye, ampul, supurge, paspas, kova, sunger, cilalayici, oda spreyi, bardak, tabak, catal, tencere, tava, mum, cicek, saksi, vida, civi, matkap, dubel, boya, fircasi, silikon, mobilya, sandalye, masa, perde, hali, jilet temizleyici, cam sil, kirec, aluminyum folyo, streç, strec film, pil, kibrit, cakmak, stor, lamba, led, vim, domestos, pril, ace, omo, persil, ariel, fairy, yumos, comfort"),
	},
	keyPersonal: {
		brands: terms("gratis, watsons, rossmann, sephora, kuafor, berber, guzellik, kozmetik, flormar, golden rose, yves rocher, farmasi, kozmetik"),
		items:  terms("sampuan, tiras bicagi, dis macunu, dis fircasi, deodorant, parfum, dus jeli, sabun, losyon, el kremi, yuz kremi, tras, jilet, ped, hijyenik, bebek bezi, oje, ruj, rimel, far, makyaj, kolonya, islak mendil, mendil, tampon, dis ipi, agiz bakim, sac kremi, sac boyasi, sac spreyi, tarak, epilasyon, agda, krem, nemlendirici, tiras kopugu, krem pudra, fondoten, maskara, kapatici, bakim"),
	},
	keyFun: {
		brands: terms("sinema, cinemaximum, cinemapink, mars, biletix, passo, kitabevi, d r, kitapyurdu, steam, playstation, xbox, nintendo, tiyatro, muze, konser, luna park, bowling, kirtasiye, hobi, oyuncak, eglence"),
		items:  terms("bilet, kitap, dergi, gazete, oyun, oyuncak, puzzle, lego, boya kalemi, defter, kalem, tuval, pc oyun, gamepass, kart oyunu, sinema, konser, tiyatro, giris, mini golf, bowling, atari"),
	},
}
