package pwned

import (
	"testing"
	"time"
)

func TestLoadConfigDefaults(t *testing.T) {
	t.Setenv("PWNED_CHECK_PROVIDER", "")
	t.Setenv("PWNED_CHECK_FAIL_CLOSED", "")
	t.Setenv("PWNED_CHECK_TIMEOUT", "")
	t.Setenv("PWNED_CHECK_LOCAL_URL", "")
	t.Setenv("PWNED_CHECK_HIBP_ENDPOINT", "")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Provider != "hibp" {
		t.Fatalf("provider = %q, want hibp", cfg.Provider)
	}
	if cfg.FailClosed {
		t.Fatal("fail closed default = true, want false")
	}
	if cfg.Timeout != 5*time.Second {
		t.Fatalf("timeout = %s, want 5s", cfg.Timeout)
	}
}

func TestLoadConfigEnvOverrides(t *testing.T) {
	t.Setenv("PWNED_CHECK_PROVIDER", " LOCAL ")
	t.Setenv("PWNED_CHECK_FAIL_CLOSED", "true")
	t.Setenv("PWNED_CHECK_TIMEOUT", "1.5")
	t.Setenv("PWNED_CHECK_LOCAL_URL", " http://127.0.0.1:8000 ")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Provider != "local" || !cfg.FailClosed {
		t.Fatalf("cfg = %+v, want local fail-closed", cfg)
	}
	if cfg.Timeout != 1500*time.Millisecond {
		t.Fatalf("timeout = %s, want 1.5s", cfg.Timeout)
	}
}

func TestLoadConfigRejectsInvalidProvider(t *testing.T) {
	t.Setenv("PWNED_CHECK_PROVIDER", "bogus")

	if _, err := LoadConfig(); err == nil {
		t.Fatal("LoadConfig succeeded, want invalid provider error")
	}
}

func TestLoadConfigRejectsMissingLocalURL(t *testing.T) {
	t.Setenv("PWNED_CHECK_PROVIDER", "local")

	if _, err := LoadConfig(); err == nil {
		t.Fatal("LoadConfig succeeded, want missing local URL error")
	}
}

func TestLoadConfigRejectsInvalidTimeout(t *testing.T) {
	t.Setenv("PWNED_CHECK_TIMEOUT", "0")

	if _, err := LoadConfig(); err == nil {
		t.Fatal("LoadConfig succeeded, want invalid timeout error")
	}
}

func TestLoadConfigRejectsInvalidLocalURL(t *testing.T) {
	t.Setenv("PWNED_CHECK_PROVIDER", "local")
	t.Setenv("PWNED_CHECK_LOCAL_URL", "file:///tmp/mirror")

	if _, err := LoadConfig(); err == nil {
		t.Fatal("LoadConfig succeeded, want invalid local URL error")
	}
}
