package pwned

import (
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Provider     string
	FailClosed   bool
	Timeout      time.Duration
	LocalURL     string
	HIBPEndpoint string
}

func LoadConfig() (Config, error) {
	cfg := Config{
		Provider:     "hibp",
		Timeout:      5 * time.Second,
		HIBPEndpoint: "https://api.pwnedpasswords.com/range/",
	}

	if value := os.Getenv("PWNED_CHECK_PROVIDER"); value != "" {
		cfg.Provider = strings.ToLower(strings.TrimSpace(value))
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
		cfg.LocalURL = strings.TrimSpace(value)
	}
	if value := os.Getenv("PWNED_CHECK_HIBP_ENDPOINT"); value != "" {
		cfg.HIBPEndpoint = strings.TrimSpace(value)
	}

	switch cfg.Provider {
	case "hibp", "local":
	default:
		return Config{}, fmt.Errorf("invalid provider %q", cfg.Provider)
	}
	if cfg.Provider == "local" && cfg.LocalURL == "" {
		return Config{}, fmt.Errorf("missing PWNED_CHECK_LOCAL_URL for provider=local")
	}
	if cfg.Provider == "local" {
		if _, err := validateHTTPURL("PWNED_CHECK_LOCAL_URL", cfg.LocalURL); err != nil {
			return Config{}, err
		}
	}
	if err := validateHIBPEndpoint(cfg.HIBPEndpoint); err != nil {
		return Config{}, err
	}

	return cfg, nil
}

func validateHIBPEndpoint(value string) error {
	parsed, err := validateHTTPURL("PWNED_CHECK_HIBP_ENDPOINT", value)
	if err != nil {
		return err
	}
	if strings.EqualFold(parsed.Hostname(), "api.pwnedpasswords.com") && parsed.Scheme != "https" {
		return fmt.Errorf("PWNED_CHECK_HIBP_ENDPOINT must use https for api.pwnedpasswords.com")
	}
	return nil
}

func validateHTTPURL(name, value string) (*url.URL, error) {
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return nil, fmt.Errorf("invalid %s", name)
	}
	switch parsed.Scheme {
	case "http", "https":
		return parsed, nil
	default:
		return nil, fmt.Errorf("invalid %s scheme %q", name, parsed.Scheme)
	}
}

func isTruthy(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "yes":
		return true
	default:
		return false
	}
}
