#!/bin/bash
# Run anf's unit tests. XCTest/Swift-Testing need Xcode; anf builds with Command
# Line Tools, so tests run via a small built-in harness as an executable target.
set -euo pipefail
cd "$(dirname "$0")"
swift run anfTests "$@"
