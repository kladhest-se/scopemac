# SPDX-License-Identifier: GPL-3.0-or-later
# Convenience targets wrapping the existing scripts. Requires macOS with Xcode or the Command Line Tools.
APP := build/ScopeMac.app

.PHONY: all build package macos-run test release-tests clean

all: package

build:
	./build.sh

package: build
	./package.sh

# Quit any running ScopeMac normally (so it releases the USB interface and returns the
# scope to local control, and its executable is not replaced while running), then
# build, package and launch the fresh bundle.
macos-run:
	@if pgrep -x ScopeMac >/dev/null; then \
		echo "Quitting running ScopeMac…"; \
		osascript -e 'quit app "ScopeMac"' >/dev/null 2>&1 || true; \
		for i in $$(seq 1 20); do pgrep -x ScopeMac >/dev/null || break; sleep 0.5; done; \
		if pgrep -x ScopeMac >/dev/null; then echo "ScopeMac is still running; quit it and retry." >&2; exit 1; fi; \
	fi
	$(MAKE) package
	open "$(APP)"

test: package
	./build/ScopeMac.app/Contents/MacOS/ScopeMac --self-test --fixtures "$(CURDIR)/Fixtures"
	./test-usb.sh

release-tests:
	python3 -m unittest discover -s tests -v

clean:
	rm -rf build
