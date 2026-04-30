.PHONY: fmt test coverage fuzz-smoke fuzz-release fuzz-nightly vet staticcheck build smoke docker-smoke docker-pam-smoke package-linux validate

BIN := dist/pwned-check
PAM_HELPER_BIN := dist/pwned-check-pam-helper
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=$(VERSION)
FUZZ_PACKAGE := ./internal/pwned
FUZZ_TARGET := FuzzParseRangeResponse

fmt:
	gofmt -w .

test:
	go test ./...

coverage:
	./scripts/coverage-threshold.sh

fuzz-smoke:
	go test $(FUZZ_PACKAGE) -run '^$$' -fuzz=$(FUZZ_TARGET) -fuzztime=5s

fuzz-release:
	go test $(FUZZ_PACKAGE) -run '^$$' -fuzz=$(FUZZ_TARGET) -fuzztime=60s

fuzz-nightly:
	go test $(FUZZ_PACKAGE) -run '^$$' -fuzz=$(FUZZ_TARGET) -fuzztime=5m

vet:
	go vet ./...

staticcheck:
	go run honnef.co/go/tools/cmd/staticcheck ./...

build:
	go build -ldflags "$(LDFLAGS)" -o $(BIN) ./cmd/pwned-check
	go build -o $(PAM_HELPER_BIN) ./cmd/pwned-check-pam-helper

smoke: build
	go run ./scripts/smoke_binary.go $(BIN)
	printf 'password\n' | PWNED_CHECK_PROVIDER=hibp PWNED_CHECK_HIBP_ENDPOINT=http://127.0.0.1:9/range/ PWNED_CHECK_FAIL_CLOSED=false $(PAM_HELPER_BIN) --checker $(BIN) --timeout 3s

docker-smoke:
	./scripts/docker-smoke.sh

docker-pam-smoke:
	./scripts/docker-pam-smoke.sh

package-linux:
	./scripts/package-linux-artifact.sh --version "$(VERSION)" --goarch amd64
	./scripts/package-linux-artifact.sh --version "$(VERSION)" --goarch arm64

validate:
	./scripts/validate-before-push.sh
