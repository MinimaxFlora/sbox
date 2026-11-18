SHELL := /bin/bash
VERSION := $(shell head -1 VERSION)
DIST := dist
FILES := sbox.sh install.sh src VERSION README.md CHANGELOG.md LICENSE

.PHONY: all lint check syntax test package clean release

all: lint test

lint: syntax
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -x -S warning sbox.sh install.sh tests/test.sh src/lib/*.sh && echo 'shellcheck: ok'; \
	else \
		echo 'shellcheck 未安装，跳过'; \
	fi

syntax:
	@for f in sbox.sh install.sh tests/test.sh src/lib/*.sh; do bash -n "$$f" || exit 1; done
	@python3 -m py_compile src/subserver/sbox-sub.py
	@echo 'syntax: ok'

test:
	@bash tests/test.sh

package: clean
	@mkdir -p $(DIST)/sbox-$(VERSION)
	@cp -a $(FILES) $(DIST)/sbox-$(VERSION)/
	@tar -czf $(DIST)/sbox-$(VERSION).tar.gz -C $(DIST) sbox-$(VERSION)
	@(cd $(DIST) && sha256sum sbox-$(VERSION).tar.gz > sbox-$(VERSION).tar.gz.sha256)
	@echo "打包完成：$(DIST)/sbox-$(VERSION).tar.gz"

release: package
	@echo "发布：git tag -a v$(VERSION) -m 'v$(VERSION)' && git push origin v$(VERSION)"

clean:
	@rm -rf $(DIST)
