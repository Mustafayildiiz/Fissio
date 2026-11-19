package main

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// specRoutes docs/openapi.yaml'daki "METHOD /yol" ciftlerini okur (YAML kutuphanesi gerektirmez: paths altinda 2 bosluk
// girintili yol, 4 bosluk girintili HTTP yontemi).
func specRoutes(t *testing.T) map[string]bool {
	t.Helper()
	f, err := os.Open(filepath.Join("..", "..", "docs", "openapi.yaml"))
	if err != nil {
		t.Fatalf("openapi.yaml okunamadi: %v", err)
	}
	defer f.Close()
	pathRe := regexp.MustCompile(`^  (/[^\s:]*):\s*$`)
	methodRe := regexp.MustCompile(`^    (get|post|put|delete|patch):\s*$`)
	out := map[string]bool{}
	inPaths, cur := false, ""
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if strings.HasPrefix(line, "paths:") {
			inPaths = true
			continue
		}
		if inPaths && line != "" && !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "#") {
			inPaths = false // sonraki ust duzey anahtar (components...)
		}
		if !inPaths {
			continue
		}
		if m := pathRe.FindStringSubmatch(line); m != nil {
			cur = m[1]
		} else if m := methodRe.FindStringSubmatch(line); m != nil && cur != "" {
			out[strings.ToUpper(m[1])+" "+cur] = true
		}
	}
	return out
}

var ginParam = regexp.MustCompile(`:([A-Za-z_]+)`)

// TestRoutesMatchOpenAPISpec: auth servisinin gercek rota tablosu ile belgelenen sozlesme birbirinden sapamaz.
func TestRoutesMatchOpenAPISpec(t *testing.T) {
	spec := specRoutes(t)
	if len(spec) < 10 {
		t.Fatalf("spec cok kisa: %d", len(spec))
	}
	r := buildRouter(&handler{})
	actual := map[string]bool{}
	for _, rt := range r.Routes() {
		actual[rt.Method+" "+ginParam.ReplaceAllString(rt.Path, "{$1}")] = true
	}
	var missingInSpec, missingInCode []string
	for k := range actual {
		if !spec[k] {
			missingInSpec = append(missingInSpec, k)
		}
	}
	for k := range spec {
		// Bu servise ait yollar: /auth/* ve /health (OPTIONS vb. yok).
		path := k[strings.Index(k, " ")+1:]
		if (strings.HasPrefix(path, "/auth/") || path == "/health") && !actual[k] {
			missingInCode = append(missingInCode, k)
		}
	}
	sort.Strings(missingInSpec)
	sort.Strings(missingInCode)
	if len(missingInSpec) > 0 {
		t.Errorf("koda kayitli ama docs/openapi.yaml'da olmayan rotalar: %v", missingInSpec)
	}
	if len(missingInCode) > 0 {
		t.Errorf("docs/openapi.yaml'da olup auth servisinde kayitli olmayan rotalar: %v", missingInCode)
	}
}
