// Fiş başlığında işletme adını seçmek için bilinen markalar: Go `category_lexicon.go` sözlüğünün tüm
// `brands` listelerinin birleşimi (üretimde kategorilerin `keywords` kolonu boş olduğundan Go
// `enrichCats` tam olarak bunları ekler). Kategori motoru taşınmaz; liste yalnızca işletme satırı
// seçimi içindir. foldTR formunda, sıralı. Sürüklenme `testdata/merchant_brands.json` ile yakalanır
// (Go ve Dart testleri aynı listeyi doğrular). Kullanıcının sunucuda eklediği ek `keywords` burada yok.
const List<String> merchantBrands = [
  'a101', 'adidas', 'akaryakit', 'alpet', 'amazon prime', 'apple', 'arcelik', 'aski', 'ayakkabi',
  'ayedas', 'aytemiz', 'bakkal', 'balikci', 'baskentgaz', 'bauhaus', 'baydoner', 'bedas',
  'bellona', 'berber', 'bershka', 'beymen', 'biletix', 'bilgisayar', 'bim', 'bimeks', 'bitaksi',
  'blutv', 'bowling', 'boyner', 'bp', 'bsfd', 'bufe', 'burger', 'burger king', 'butik', 'cafe',
  'caffe nero', 'carrefour', 'carrefoursa', 'cigkofte', 'cinemapink', 'cinemaximum', 'colins',
  'd r', 'd smart', 'defacto', 'dekorasyon', 'digiturk', 'dis hekimi', 'disney', 'dogtas',
  'domino', 'dominos', 'doner', 'eczane', 'eczanem', 'eczanesi', 'eglence', 'ekomini',
  'elektronik', 'emsan', 'enerjisa', 'english home', 'ev tekstili', 'evidea', 'exxen', 'farmasi',
  'file market', 'flo', 'flormar', 'gimsa', 'giyim', 'gloria jeans', 'golden rose', 'gratis',
  'gsm', 'guzellik', 'h m', 'hakmar', 'happy center', 'hastane', 'hastanesi', 'havaist',
  'hepsiburada', 'hgs', 'hirdavat', 'hm', 'hobi', 'ido', 'iett', 'igdas', 'ikea', 'ipekyol',
  'iski', 'ispark', 'istanbulkart', 'istikbal', 'jack jones', 'jysk', 'kadoil', 'kafe',
  'kafeterya', 'kahvalti', 'kahve dunyasi', 'karaca', 'kasap', 'kebap', 'kfc', 'kigili', 'kiler',
  'kirtasiye', 'kitabevi', 'kitapyurdu', 'klinik', 'koctas', 'kofteci', 'konser', 'koton',
  'kozmetik', 'kuafor', 'laboratuvar', 'lc waikiki', 'lcw', 'lokanta', 'lukoil', 'luna park',
  'macro', 'macrocenter', 'madame coco', 'manav', 'market', 'marmaray', 'mars', 'marti', 'mavi',
  'mcdonald', 'mcdonalds', 'media markt', 'mediamarkt', 'medikal', 'metro istanbul', 'meyhane',
  'migros', 'mobilya', 'moil', 'mondi', 'muze', 'n11', 'nalbur', 'netflix', 'network', 'nike',
  'nintendo', 'ocakbasi', 'ogs', 'onur market', 'opet', 'optik', 'otobus', 'otopark', 'oyuncak',
  'ozdilek home', 'passo', 'pastane', 'pastanesi', 'pegasus', 'petrol', 'petrol ofisi', 'pizza',
  'playstation', 'poliklinik', 'popeyes', 'pull bear', 'puma', 'restaurant', 'restoran',
  'rossmann', 'saglik', 'samsung', 'sarar', 'sephora', 'shell', 'simit sarayi', 'sinema', 'sok',
  'spotify', 'starbucks', 'steam', 'stradivarius', 'sunpet', 'supermarket', 'superonline', 'taksi',
  'tarim kredi', 'tavuk dunyasi', 'tedas', 'teknosa', 'tekstil', 'tekzen', 'telekom', 'thy',
  'tip merkezi', 'tiyatro', 'tod', 'total', 'totalenergies', 'turk hava yollari', 'turk telekom',
  'turkcell', 'turknet', 'uber', 'vakko', 'vatan', 'vatan bilgisayar', 'vestel', 'vodafone',
  'watsons', 'xbox', 'xiaomi', 'yapi market', 'yatas', 'youtube', 'yves rocher', 'zara',
];
