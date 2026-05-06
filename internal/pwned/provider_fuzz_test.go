package pwned

import (
	"strings"
	"testing"
)

const (
	maxFuzzRangeResponseBytes = 4 * 1024
	fuzzRangeResponseSuffix   = "ABC"
)

func FuzzParseRangeResponse(f *testing.F) {
	seeds := []string{
		"",
		"ABC:1\nFFF:7\n",
		"abc:1\n",
		"ABC:not-a-number\n",
		"ABC\n",
		":1\n",
		"ABC:1\r\nDEF:2\r\n",
		strings.Repeat("A", 128) + ":1\n",
	}
	for _, seed := range seeds {
		f.Add(seed)
	}

	f.Fuzz(func(t *testing.T, body string) {
		if len(body) > maxFuzzRangeResponseBytes {
			body = body[:maxFuzzRangeResponseBytes]
		}

		count, err := ParseRangeResponse(strings.NewReader(body), fuzzRangeResponseSuffix)
		if err != nil {
			return
		}
		if count < 0 {
			t.Fatalf("count = %d, want non-negative", count)
		}
	})
}
