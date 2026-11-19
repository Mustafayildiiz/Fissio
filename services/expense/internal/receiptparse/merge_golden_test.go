package receiptparse

import "testing"

// testdata/merge.json: Dart receipt_parser/merge.dart ayni vektorleri okur.
func TestMergePageTextsGoldenVectors(t *testing.T) {
	var data struct {
		Cases []struct {
			Name  string   `json:"name"`
			Pages []string `json:"pages"`
			Out   string   `json:"out"`
		} `json:"cases"`
	}
	loadTestdata(t, "merge.json", &data)
	if len(data.Cases) < 5 {
		t.Fatalf("merge.json beklenenden kisa: %d", len(data.Cases))
	}
	for _, c := range data.Cases {
		if got := MergePageTexts(c.Pages); got != c.Out {
			t.Errorf("%s: got %q want %q", c.Name, got, c.Out)
		}
	}
}
