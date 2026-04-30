.PHONY: fmt test vet staticcheck build smoke validate

BIN := dist/pwned-check
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

smoke: build
	go run ./scripts/smoke_binary.go $(BIN)

validate:
	./scripts/validate-before-push.sh
