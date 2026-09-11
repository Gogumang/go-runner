.PHONY: build test app run install uninstall check clean

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

run: app
	pkill -x GoRunner 2>/dev/null || true
	open "build/go-runner.app"

install:
	./scripts/install.sh

uninstall:
	./scripts/uninstall.sh

check:
	./scripts/ralph-check.sh

clean:
	rm -rf .build .build-* build
