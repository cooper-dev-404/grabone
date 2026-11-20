#!/bin/bash
set -euo pipefail
project="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project"
mkdir -p .build/modules
xcrun swiftc -parse-as-library -O -module-cache-path .build/modules \
    -o .build/Regression Sources/Core.swift Sources/Hotkeys.swift Sources/TranslationLayer.swift Tests/Regression.swift
.build/Regression
