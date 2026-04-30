.PHONY: fmt test vet staticcheck build smoke validate

BIN := dist/pwned-check

fmt:
	gofmt -w .

test:
	go test ./...

vet:
	go vet ./...

staticcheck:
	go run honnef.co/go/tools/cmd/staticcheck ./...

build:
	go build -o $(BIN) ./cmd/pwned-check

smoke: build
	go run ./scripts/smoke_binary.go $(BIN)

validate:
	./scripts/validate-before-push.sh
