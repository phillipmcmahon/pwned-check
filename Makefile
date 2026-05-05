.PHONY: fmt test coverage fuzz-smoke fuzz-release fuzz-nightly vet staticcheck build native-pam-fmt native-pam-build native-pam-test native-pam-memory-check native-pam-deps native-pam-symbols native-pam-harness native-pam-ubuntu-smoke native-pam-ubuntu-host-package-smoke native-pam-ubuntu-deb-package-smoke native-pam-ubuntu-hardening-assessment native-pam-fedora-host-package-smoke native-pam-fedora-rpm-package-smoke native-pam-fedora-selinux-assessment native-pam-distro-smoke native-pam-generic-package-smoke native-pam-arch-package-smoke native-pam-alpine-package-smoke smoke docker-smoke docker-pam-smoke package-linux package-native-pam-debian-artifact package-native-pam-debian package-native-pam-rpm-artifact package-native-pam-rpm package-native-pam-generic package-native-pam-arch package-native-pam-alpine native-pam-apt-repository native-pam-apt-repo-smoke native-pam-rpm-repository native-pam-rpm-repo-smoke native-pam-alpine-repository native-pam-alpine-repo-smoke native-pam-arch-repository native-pam-arch-repo-smoke native-pam-live-repo-smokes native-pam-repo-endpoint-check native-pam-release-provenance archive-release-to-nas github-ci-watch github-workflow-status validate

BIN := dist/pwned-check
PAM_HELPER_BIN := dist/pwned-check-pam-helper
NATIVE_PAM_BIN := dist/pam_pwned_check.so
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=$(VERSION) -X github.com/phillipmcmahon/pwned-check/internal/pamhelper.Version=$(VERSION)
FUZZ_PACKAGE := ./internal/pwned
FUZZ_TARGET := FuzzParseRangeResponse
APT_REPO_SMOKE_HOST ?= codex-vm-ubuntu
RPM_REPO_SMOKE_HOST ?= codex-vm-fedora
ALPINE_REPO_SMOKE_HOST ?= codex-vm-alpine
ARCH_REPO_SMOKE_HOST ?= codex-vm-arch

fmt:
	gofmt -w .
	cargo fmt

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
	go build -ldflags "$(LDFLAGS)" -o $(PAM_HELPER_BIN) ./cmd/pwned-check-pam-helper

native-pam-fmt:
	cargo fmt --check

native-pam-build:
	cargo build --release -p pam-pwned-check
	mkdir -p dist
	if [ -f target/release/libpam_pwned_check.so ]; then \
		cp target/release/libpam_pwned_check.so $(NATIVE_PAM_BIN); \
	else \
		cp target/release/libpam_pwned_check.dylib dist/libpam_pwned_check.dylib; \
		echo "built host dynamic library at dist/libpam_pwned_check.dylib; Linux builds produce $(NATIVE_PAM_BIN)"; \
	fi

native-pam-test:
	cargo test -p pam-pwned-check

native-pam-memory-check:
	./scripts/native-pam-memory-check.sh

native-pam-deps: native-pam-build
	if [ -f $(NATIVE_PAM_BIN) ]; then \
		./scripts/native-pam-deps-check.sh $(NATIVE_PAM_BIN); \
	else \
		echo "native PAM dependency allowlist skipped: $(NATIVE_PAM_BIN) not produced for this host"; \
	fi

native-pam-symbols: native-pam-build
	if [ -f $(NATIVE_PAM_BIN) ]; then \
		./scripts/native-pam-symbols-check.sh $(NATIVE_PAM_BIN); \
	else \
		echo "native PAM symbol check skipped: $(NATIVE_PAM_BIN) not produced for this host"; \
	fi

native-pam-harness:
	./scripts/native-pam-harness.sh

native-pam-ubuntu-smoke:
	./scripts/native-pam-ubuntu-smoke.sh run

native-pam-ubuntu-host-package-smoke:
	./scripts/native-pam-ubuntu-host-package-smoke.sh

native-pam-ubuntu-deb-package-smoke:
	./scripts/native-pam-ubuntu-deb-package-smoke.sh

native-pam-ubuntu-hardening-assessment:
	./scripts/native-pam-ubuntu-hardening-assessment.sh

native-pam-fedora-host-package-smoke:
	./scripts/native-pam-fedora-host-package-smoke.sh

native-pam-fedora-rpm-package-smoke:
	./scripts/native-pam-fedora-rpm-package-smoke.sh

native-pam-fedora-selinux-assessment:
	./scripts/native-pam-fedora-selinux-assessment.sh

native-pam-distro-smoke:
	./scripts/native-pam-distro-smoke.sh

native-pam-generic-package-smoke:
	./scripts/native-pam-generic-package-smoke.sh

native-pam-arch-package-smoke:
	./scripts/native-pam-arch-package-smoke.sh

native-pam-alpine-package-smoke:
	./scripts/native-pam-alpine-package-smoke.sh

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

package-native-pam-debian-artifact:
	./scripts/package-native-pam-debian-artifact.sh --version "$(VERSION)"

package-native-pam-debian:
	./scripts/package-native-pam-debian-package.sh --version "$(VERSION)"

package-native-pam-rpm-artifact:
	./scripts/package-native-pam-rpm-artifact.sh --version "$(VERSION)"

package-native-pam-rpm:
	./scripts/package-native-pam-rpm-package.sh --version "$(VERSION)"

package-native-pam-generic:
	./scripts/package-native-pam-generic-artifact.sh --version "$(VERSION)"

package-native-pam-arch:
	./scripts/package-native-pam-arch-package.sh --version "$(VERSION)"

package-native-pam-alpine:
	./scripts/package-native-pam-alpine-package.sh --version "$(VERSION)"

native-pam-apt-repository:
	./scripts/build-native-pam-apt-repository.sh

native-pam-apt-repo-smoke:
	./scripts/native-pam-apt-repo-smoke.sh --host "$(APT_REPO_SMOKE_HOST)"

native-pam-rpm-repository:
	./scripts/build-native-pam-rpm-repository.sh

native-pam-rpm-repo-smoke:
	./scripts/native-pam-rpm-repo-smoke.sh --host "$(RPM_REPO_SMOKE_HOST)"

native-pam-alpine-repository:
	./scripts/build-native-pam-alpine-repository.sh

native-pam-alpine-repo-smoke:
	./scripts/native-pam-alpine-repo-smoke.sh --host "$(ALPINE_REPO_SMOKE_HOST)"

native-pam-arch-repository:
	./scripts/build-native-pam-arch-repository.sh

native-pam-arch-repo-smoke:
	./scripts/native-pam-arch-repo-smoke.sh --host "$(ARCH_REPO_SMOKE_HOST)"

native-pam-live-repo-smokes:
	./scripts/native-pam-live-repo-smokes.sh

native-pam-repo-endpoint-check:
	./scripts/native-pam-repo-endpoint-check.sh

native-pam-release-provenance:
	./scripts/native-pam-release-provenance.sh

archive-release-to-nas:
	./scripts/archive-release-to-nas.sh --version "$(VERSION)"

github-ci-watch:
	./scripts/github-ci-watch.sh

github-workflow-status:
	./scripts/github-workflow-status.sh

validate:
	./scripts/validate-before-push.sh
