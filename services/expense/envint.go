package main

import (
	"os"
	"strconv"
)

// envInt, pozitif bir tamsayi ortam degiskenini okur; yoksa/gecersizse def doner.
func envInt(name string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(name)); err == nil && v > 0 {
		return v
	}
	return def
}
