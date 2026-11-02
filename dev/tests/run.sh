#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
archive=${1:?Pass the pinned upstream tar.gz path}
archive=$(realpath "$archive")
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
printf '%s  %s\n' a7ca803a2f7fb40befa7e208886911d139c643f1a50031eabc0b78cac47dad33 "$archive" | sha256sum -c -
tar -xzf "$archive" -C "$build" --strip-components=1
patch --batch -p1 -d "$build" < "$repo/dev/packaging/application-auth.patch"
cmake -S "$build" -B "$build/build" -DBuildDocumentation=OFF -DCMAKE_BUILD_TYPE=Debug
cmake --build "$build/build" --parallel 2
(cd "$build/build" && ctest --output-on-failure)
bash -n "$repo/smtp-oauth-deploy.sh"
shellcheck "$repo/smtp-oauth-deploy.sh" "$repo/dev/packaging/build-rpm.sh" "$repo/dev/tests/run.sh"
bash "$repo/dev/tests/deployment.sh"

bash "$repo/dev/tests/repositories.sh"
