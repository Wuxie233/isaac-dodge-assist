#!/usr/bin/env bash
# Build and run the RunArchive regression on Linux (dotnet 8 SDK and gzip).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
dotnet build "$here/run_archive/RunArchiveRegression.csproj" -nologo -v q --artifacts-path "$out" >"$out/build.log" || { cat "$out/build.log"; exit 1; }
dotnet "$(find "$out" -name RunArchiveRegression.dll -path '*bin*' | head -1)"
