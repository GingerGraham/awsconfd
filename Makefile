.PHONY: dev-setup test

dev-setup:
	./scripts/setup-pre-commit.sh

test:
	bash tests/run-tests.sh