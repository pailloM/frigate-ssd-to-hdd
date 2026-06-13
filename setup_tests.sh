#!/bin/bash

# Setup script for test environment

set -euo pipefail

echo "🔧 Setting up test environment..."

# Check if BATS is installed
if ! command -v bats &> /dev/null; then
    echo "❌ BATS is not installed"
    echo "Install with: brew install bats-core (macOS) or sudo apt-get install bats (Ubuntu)"
    exit 1
fi

# Check if ShellCheck is installed
if ! command -v shellcheck &> /dev/null; then
    echo "⚠️  ShellCheck not found (optional, but recommended)"
else
    echo "✅ ShellCheck found"
fi

# Check if ShFmt is installed
if ! command -v shfmt &> /dev/null; then
    echo "⚠️  ShFmt not found (optional, but recommended)"
else
    echo "✅ ShFmt found"
fi

# Make scripts executable
chmod +x ssd-to-hdd.sh test_ssd_to_hdd.bats setup_tests.sh

echo "✅ Test environment ready!"
echo ""
echo "Quick start:"
echo "  Run all tests:     Ctrl+Shift+B → 'Run all BATS tests'"
echo "  Run single test:   Ctrl+Shift+B → 'Run single test (verbose)'"
echo "  Lint script:       Ctrl+Shift+B → 'Lint bash script'"
echo "  Debug script:      F5 → 'Debug main script'"
