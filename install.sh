#!/bin/bash
# awsconfd install script
# Safely downloads awsconfd, verifies checksum, and installs to ~/.local/bin

set -euo pipefail

readonly INSTALLER_VERSION="1.1.0"
REPO="${REPO:-https://github.com/GingerGraham/awsconfd}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
MODIFY_PATH="${MODIFY_PATH:-0}"

# Detect which hash tool to use
if command -v sha256sum >/dev/null 2>&1; then
    hash_cmd="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    hash_cmd="shasum -a 256"
else
    echo "ERROR: Neither sha256sum nor shasum found. Cannot verify checksum." >&2
    exit 1
fi

main() {
    echo "awsconfd installer"
    echo "Installer version: $INSTALLER_VERSION"
    echo "Repository: $REPO"
    echo "Branch: $BRANCH"
    echo "Install directory: $INSTALL_DIR"
    echo ""

    # Create install directory if needed
    mkdir -p "$INSTALL_DIR"

    # Stage source files in a temp directory. Prefer local checkout source
    # when this installer is run from a cloned repo; otherwise download.
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" EXIT

    local source_mode="remote"
    local source_desc=""
    local source_script="$tmpdir/awsconfd"
    local source_checksum="$tmpdir/awsconfd.sha256"
    local installer_path="${BASH_SOURCE[0]:-}"

    if [[ -n "$installer_path" && -f "$installer_path" ]]; then
        local installer_dir
        installer_dir=$(cd "$(dirname "$installer_path")" && pwd -P)
        if [[ -f "$installer_dir/awsconfd" ]]; then
            source_mode="local"
            source_desc="$installer_dir/awsconfd"
            cp "$installer_dir/awsconfd" "$source_script"
            if [[ -f "$installer_dir/awsconfd.sha256" ]]; then
                cp "$installer_dir/awsconfd.sha256" "$source_checksum"
            fi
        fi
    fi

    local script_url="${REPO//.git/}/raw/$BRANCH/awsconfd"
    local checksum_url="${REPO//.git/}/raw/$BRANCH/awsconfd.sha256"
    if [[ "$source_mode" == "local" ]]; then
        echo "Source mode: local checkout"
        echo "  from: $source_desc"
    else
        echo "Source mode: remote download"
        echo "Downloading awsconfd..."

        # Detect which download tool to use
        local download_cmd
        if command -v curl >/dev/null 2>&1; then
            download_cmd="curl -fsSL -H Cache-Control:no-cache -H Pragma:no-cache"
        elif command -v wget >/dev/null 2>&1; then
            download_cmd="wget -q -O- --header=Cache-Control:no-cache --header=Pragma:no-cache"
        else
            echo "ERROR: Neither curl nor wget found. Cannot download." >&2
            exit 1
        fi

        local cache_bust
        cache_bust=$(date +%s)
        local script_url_cb="${script_url}?_=${cache_bust}"
        local checksum_url_cb="${checksum_url}?_=${cache_bust}"

        echo "  from: $script_url"

        if ! $download_cmd "$script_url_cb" > "$source_script"; then
            echo "ERROR: Failed to download awsconfd" >&2
            exit 1
        fi

        if ! $download_cmd "$checksum_url_cb" > "$source_checksum"; then
            echo "WARNING: Could not verify checksum (checksum file not found)" >&2
        fi
    fi

    # Always compute the source file hash so we can compare/update even
    # when checksum metadata cannot be fetched.
    local actual
    actual=$($hash_cmd < "$source_script" | awk '{print $1}')

    # Download and verify checksum
    echo "Verifying checksum..."
    if [[ ! -f "$source_checksum" ]]; then
        echo "WARNING: Could not verify checksum (checksum file not found)" >&2
    else
        # Extract just the hash from the checksum file
        local expected
        expected=$(awk '{print $1}' "$source_checksum")

        if [[ "$expected" != "$actual" ]]; then
            echo "ERROR: Checksum mismatch!" >&2
            echo "  Expected: $expected" >&2
            echo "  Got:      $actual" >&2
            exit 1
        fi
        echo "  OK"
    fi

    local target="$INSTALL_DIR/awsconfd"
    local existing_hash=""
    if [[ -f "$target" ]]; then
        existing_hash=$($hash_cmd < "$target" | awk '{print $1}')
        if [[ "$existing_hash" == "$actual" ]]; then
            echo "Existing installation already matches installer source. Reinstalling to ensure permissions and freshness."
        else
            echo "Existing installation differs from installer source. Updating now."
        fi
    else
        echo "No existing installation found. Installing new binary."
    fi

    # Install
    echo "Installing..."
    chmod +x "$source_script"
    local target_tmp
    target_tmp=$(mktemp "$INSTALL_DIR/.awsconfd.XXXXXX")
    cp "$source_script" "$target_tmp"
    chmod 0755 "$target_tmp"
    mv -f "$target_tmp" "$target"

    echo "Installed to: $target"
    echo ""

    # Check if INSTALL_DIR is in PATH
    if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
        echo "NOTE: $INSTALL_DIR is not in your PATH"
        echo ""
        echo "Add it to your shell config:"
        echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
        echo ""
        if [[ ${MODIFY_PATH:-0} == "1" ]]; then
            local shell_rc
            if [[ -f $HOME/.bashrc ]]; then
                echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$HOME/.bashrc"
                echo "Added to ~/.bashrc"
            elif [[ -f $HOME/.zshrc ]]; then
                echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$HOME/.zshrc"
                echo "Added to ~/.zshrc"
            fi
        fi
    fi

    # Verify installation
    echo ""
    echo "Verifying installation..."
    if "$target" --version; then
        echo ""
        echo "Installation complete!"
        echo "Next steps:"
        echo "  1. Run: awsconfd init"
        echo "  2. Create fragments in ~/.aws/config.d/"
        echo "  3. Run: awsconfd build"
        echo "  4. Install watcher: awsconfd watch --install"
    else
        echo "ERROR: Installation verification failed" >&2
        exit 1
    fi
}

main "$@"
