package pwned

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestParseRangeResponseMatchesSuffix(t *testing.T) {
	count, err := ParseRangeResponse(strings.NewReader("ABC:1\nFFF:7\n"), "fff")
	if err != nil {
		t.Fatal(err)
	}
	if count != 7 {
		t.Fatalf("count = %d, want 7", count)
	}
}

func TestParseRangeResponseIgnoresMalformedRows(t *testing.T) {
	count, err := ParseRangeResponse(strings.NewReader("not-a-row\nABC:not-a-number\nFFF:3\n"), "abc")
	if err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("count = %d, want 0", count)
	}
}

func TestParseRangeResponseIgnoresNegativeCount(t *testing.T) {
	count, err := ParseRangeResponse(strings.NewReader("ABC:-1\n"), "abc")
	if err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("count = %d, want 0", count)
	}
}

func TestRangeProviderCallsLocalRangeEndpoint(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/range/ABCDE" {
			t.Fatalf("path = %q, want /range/ABCDE", r.URL.Path)
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("11111111111111111111111111111111111:9\n"))
	}))
	defer server.Close()

	provider := NewLocalProvider(server.URL, time.Second)
	count, err := provider.Lookup("ABCDE", "11111111111111111111111111111111111")
	if err != nil {
		t.Fatal(err)
	}
	if count != 9 {
		t.Fatalf("count = %d, want 9", count)
	}
}

func TestHIBPProviderSetsPrivacyHeaders(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Add-Padding") != "true" {
			t.Fatal("missing Add-Padding header")
		}
		if r.Header.Get("User-Agent") == "" {
			t.Fatal("missing User-Agent header")
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("11111111111111111111111111111111111:2\n"))
	}))
	defer server.Close()

	provider := NewHIBPProvider(server.URL, time.Second)
	count, err := provider.Lookup("ABCDE", "11111111111111111111111111111111111")
	if err != nil {
		t.Fatal(err)
	}
	if count != 2 {
		t.Fatalf("count = %d, want 2", count)
	}
}

func TestRangeProviderTimeout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(200 * time.Millisecond)
		_, _ = w.Write([]byte("11111111111111111111111111111111111:9\n"))
	}))
	defer server.Close()

	provider := NewLocalProvider(server.URL, 10*time.Millisecond)
	_, err := provider.Lookup("ABCDE", "11111111111111111111111111111111111")
	if err == nil {
		t.Fatal("Lookup succeeded, want timeout error")
	}
	if !errors.Is(err, http.ErrHandlerTimeout) && !strings.Contains(err.Error(), "context deadline exceeded") {
		t.Fatalf("err = %v, want timeout", err)
	}
}

func TestRangeProviderRejectsZeroTimeout(t *testing.T) {
	provider := NewLocalProvider("https://example.invalid", 0)
	_, err := provider.Lookup("ABCDE", "11111111111111111111111111111111111")
	if err == nil {
		t.Fatal("Lookup succeeded, want timeout configuration error")
	}
	if !strings.Contains(err.Error(), "provider timeout must be positive") {
		t.Fatalf("err = %v, want timeout configuration error", err)
	}
}
