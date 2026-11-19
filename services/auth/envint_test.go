package main

import "testing"

func TestEnvInt(t *testing.T) {
	t.Setenv("FISSIO_T_N", "7")
	if got := envInt("FISSIO_T_N", 3); got != 7 {
		t.Fatalf("got %d", got)
	}
	for _, bad := range []string{"", "abc", "0", "-2"} {
		t.Setenv("FISSIO_T_N", bad)
		if got := envInt("FISSIO_T_N", 3); got != 3 {
			t.Fatalf("%q -> %d, want default 3", bad, got)
		}
	}
}
