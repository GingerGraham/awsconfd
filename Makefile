.DEFAULT_GOAL := help

.PHONY: help dev-setup test hash

help:
	@echo "Available targets:"
	@echo "  dev-setup  - Install local development hooks"
	@echo "  test       - Run test suite"
	@echo "  hash       - Generate awsconfd.sha256 from awsconfd"

dev-setup:
	./scripts/setup-pre-commit.sh

test:
	bash tests/run-tests.sh

hash:
	sha256sum awsconfd > awsconfd.sha256
	@echo "Updated awsconfd.sha256"