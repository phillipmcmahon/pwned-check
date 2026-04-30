package pwned

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Provider       string
	FailClosed     bool
	Timeout        time.Duration
	LocalURL       string
	HIBPEndpoint   string
	InteractiveTTY bool
}

func LoadConfig() (Config, error) {
	cfg := Config{
		Provider:     "hibp",
		Timeout:      5 * time.Second,
		HIBPEndpoint: "https://api.pwnedpasswords.com/range/",
	}

	if value := os.Getenv("PWNED_CHECK_PROVIDER"); value != "" {
		cfg.Provider = strings.ToLower(value)
	}
	if value := os.Getenv("PWNED_CHECK_FAIL_CLOSED"); value != "" {
		cfg.FailClosed = isTruthy(value)
	}
	if value := os.Getenv("PWNED_CHECK_TIMEOUT"); value != "" {
		seconds, err := strconv.ParseFloat(value, 64)
		if err != nil || seconds <= 0 {
			return Config{}, fmt.Errorf("invalid PWNED_CHECK_TIMEOUT")
		}
		cfg.Timeout = time.Duration(seconds * float64(time.Second))
	}
	if value := os.Getenv("PWNED_CHECK_LOCAL_URL"); value != "" {
		cfg.LocalURL = value
	}
	if value := os.Getenv("PWNED_CHECK_HIBP_ENDPOINT"); value != "" {
		cfg.HIBPEndpoint = value
	}

	switch cfg.Provider {
	case "hibp", "local":
	default:
		return Config{}, fmt.Errorf("invalid provider %q", cfg.Provider)
	}
	if cfg.Provider == "local" && cfg.LocalURL == "" {
		return Config{}, fmt.Errorf("missing PWNED_CHECK_LOCAL_URL for provider=local")
	}

	return cfg, nil
}

func isTruthy(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "yes":
		return true
	default:
		return false
	}
}
