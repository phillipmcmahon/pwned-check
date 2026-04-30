package pwned

import (
	"strings"
	"testing"
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
		f.Add(seed, "ABC")
	}

	f.Fuzz(func(t *testing.T, body, suffix string) {
		count, err := ParseRangeResponse(strings.NewReader(body), suffix)
		if err != nil {
			return
		}
		if count < 0 {
			t.Fatalf("count = %d, want non-negative", count)
		}
	})
}
