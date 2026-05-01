package pwned

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"strings"
)

const DefaultMinCount = 1

type Result struct {
	Pwned  bool
	Count  int
	Prefix string
}

type Provider interface {
	Lookup(prefix, suffix string) (int, error)
}

func HashParts(password string) (string, string) {
	sum := sha1.Sum([]byte(password))
	digest := strings.ToUpper(hex.EncodeToString(sum[:]))
	return digest[:5], digest[5:]
}

func Validate(password string, provider Provider) (Result, error) {
	return ValidateWithMinCount(password, provider, DefaultMinCount)
}

func ValidateWithMinCount(password string, provider Provider, minCount int) (Result, error) {
	if minCount < 1 {
		return Result{}, fmt.Errorf("min-count must be at least 1")
	}

	prefix, suffix := HashParts(password)
	count, err := provider.Lookup(prefix, suffix)
	if err != nil {
		return Result{}, err
	}
	return Result{
		Pwned:  count >= minCount,
		Count:  count,
		Prefix: prefix,
	}, nil
}
