#!/usr/bin/env bash
# Setup script for Neovim configuration

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/venv"

echo "=== Neovim Configuration Setup ==="
echo

# Python Environment Setup
echo "→ Setting up Python environment..."

# Create or update virtual environment
if [ -d "$VENV_DIR" ]; then
    echo "  Virtual environment already exists, updating..."
    "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel >/dev/null 2>&1
else
    echo "  Creating new virtual environment..."
    python3 -m venv "$VENV_DIR" --upgrade-deps
fi

# Install/upgrade required packages
echo "  Installing/upgrading pynvim and pyperclip..."
"$VENV_DIR/bin/pip" install --upgrade pynvim pyperclip >/dev/null 2>&1

# Verify installation
if "$VENV_DIR/bin/python" -c "import pynvim, pyperclip" 2>/dev/null; then
    echo "  ✓ Python environment ready"
else
    echo "  ✗ Failed to setup Python environment"
    exit 1
fi

# Future setup tasks can be added here
# echo "→ Setting up additional components..."

echo
echo "=== Setup complete! ==="