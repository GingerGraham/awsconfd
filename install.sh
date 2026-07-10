#!/bin/bash
# awsconfd install script
# Safely downloads awsconfd, verifies checksum, and installs to ~/.local/bin

set -euo pipefail

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

# Detect which download tool to use
if command -v curl >/dev/null 2>&1; then
    download_cmd="curl -fsSL"
elif command -v wget >/dev/null 2>&1; then
    download_cmd="wget -q -O-"
else
    echo "ERROR: Neither curl nor wget found. Cannot download." >&2
    exit 1
fi

main() {
    echo "awsconfd installer"
    echo "Repository: $REPO"
    echo "Branch: $BRANCH"
    echo "Install directory: $INSTALL_DIR"
    echo ""
    
    # Create install directory if needed
    mkdir -p "$INSTALL_DIR"
    
    # Download the script
    echo "Downloading awsconfd..."
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" EXIT
    
    local script_url="${REPO//.git/}/raw/$BRANCH/awsconfd"
    local checksum_url="${REPO//.git/}/raw/$BRANCH/awsconfd.sha256"
    
    echo "  from: $script_url"
    
    if ! $download_cmd "$script_url" > "$tmpdir/awsconfd"; then
        echo "ERROR: Failed to download awsconfd" >&2
        exit 1
    fi
    
    # Download and verify checksum
    echo "Verifying checksum..."
    if ! $download_cmd "$checksum_url" > "$tmpdir/awsconfd.sha256"; then
        echo "WARNING: Could not verify checksum (checksum file not found)" >&2
    else
        # Extract just the hash from the checksum file
        local expected
        expected=$(awk '{print $1}' "$tmpdir/awsconfd.sha256")
        
        # Compute actual hash
        local actual
        actual=$($hash_cmd < "$tmpdir/awsconfd" | awk '{print $1}')
        
        if [[ "$expected" != "$actual" ]]; then
            echo "ERROR: Checksum mismatch!" >&2
            echo "  Expected: $expected" >&2
            echo "  Got:      $actual" >&2
            exit 1
        fi
        echo "  OK"
    fi
    
    # Install
    echo "Installing..."
    chmod +x "$tmpdir/awsconfd"
    cp "$tmpdir/awsconfd" "$INSTALL_DIR/awsconfd"
    chmod 0755 "$INSTALL_DIR/awsconfd"
    
    echo "Installed to: $INSTALL_DIR/awsconfd"
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
    if "$INSTALL_DIR/awsconfd" --version; then
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
