.PHONY: fmt test vet staticcheck build smoke docker-smoke docker-pam-smoke package-linux validate

BIN := dist/pwned-check
PAM_HELPER_BIN := dist/pwned-check-pam-helper
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=$(VERSION)

fmt:
	gofmt -w .

test:
	go test ./...

vet:
	go vet ./...

staticcheck:
	go run honnef.co/go/tools/cmd/staticcheck ./...

build:
	go build -ldflags "$(LDFLAGS)" -o $(BIN) ./cmd/pwned-check
	go build -o $(PAM_HELPER_BIN) ./cmd/pwned-check-pam-helper

smoke: build
	go run ./scripts/smoke_binary.go $(BIN)
	printf 'password\n' | PWNED_CHECK_PROVIDER=local PWNED_CHECK_LOCAL_URL=http://127.0.0.1:9 PWNED_CHECK_FAIL_CLOSED=false $(PAM_HELPER_BIN) --checker $(BIN) --timeout 3s

docker-smoke:
	./scripts/docker-smoke.sh

docker-pam-smoke:
	./scripts/docker-pam-smoke.sh

package-linux:
	./scripts/package-linux-artifact.sh --version "$(VERSION)" --goarch amd64
	./scripts/package-linux-artifact.sh --version "$(VERSION)" --goarch arm64

validate:
	./scripts/validate-before-push.sh
