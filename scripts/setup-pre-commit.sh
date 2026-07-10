#!/usr/bin/env bash
# scripts/setup-pre-commit.sh
# Install pre-commit (if needed) and install git hooks for this repository.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

err() {
    printf 'ERROR: %s\n' "$*" >&2
}

info() {
    printf 'INFO: %s\n' "$*" >&2
}

ensure_git_repo() {
    if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        err "Not a git repository: $REPO_ROOT"
        exit 1
    fi
}

install_pre_commit() {
    if command -v pre-commit >/dev/null 2>&1; then
        info "pre-commit already installed"
        return 0
    fi

    info "pre-commit not found; attempting install"

    if command -v pipx >/dev/null 2>&1; then
        info "Installing with pipx"
        pipx install --force pre-commit
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        err "python3 is required to install pre-commit"
        exit 1
    fi

    if python3 -m pip --version >/dev/null 2>&1; then
        info "Installing with python3 -m pip --user"
        python3 -m pip install --user pre-commit
        return 0
    fi

    err "Could not install pre-commit automatically (missing pipx and python3 -m pip)"
    err "Install pre-commit manually, then re-run this script"
    exit 1
}

run_pre_commit() {
    if command -v pre-commit >/dev/null 2>&1; then
        pre-commit "$@"
        return 0
    fi
    python3 -m pre_commit "$@"
}

main() {
    ensure_git_repo
    install_pre_commit

    info "Installing git pre-commit hook"
    run_pre_commit install --install-hooks --hook-type pre-commit

    info "Validating hook configuration"
    run_pre_commit validate-config

    info "pre-commit setup complete"
    info "Optional: run 'pre-commit run --all-files' to lint all tracked files now"
}

main "$@"
