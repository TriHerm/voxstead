#!/usr/bin/env bash
set -euo pipefail

version=v1.9.5
model_hash=60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe
destination="$HOME/Library/Application Support/Voxstead/Speech"
command -v cmake >/dev/null || { printf 'Install CMake before preparing multilingual dictation.\n' >&2; exit 1; }
umask 077
mkdir -p "$destination"
stage="$(mktemp -d "$destination/.setup.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

if [[ ! -x "$destination/whisper-cli-$version" ]]; then
  git clone --quiet --depth 1 --branch "$version" https://github.com/ggml-org/whisper.cpp.git "$stage/source"
  [[ "$(git -C "$stage/source" rev-parse HEAD)" == d1be6fde11ac6e0407606b4e42fe72d34add8037 ]]
  cmake -S "$stage/source" -B "$stage/build" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=OFF -DWHISPER_BUILD_TESTS=OFF
  cmake --build "$stage/build" --target whisper-cli --parallel 6
  mv "$stage/build/bin/whisper-cli" "$destination/whisper-cli-$version"
fi

if [[ ! -f "$destination/ggml-base.bin" ]] || ! printf '%s  %s\n' "$model_hash" "$destination/ggml-base.bin" | shasum -a 256 --check --status; then
  curl --fail --silent --show-error --location --retry 3 \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin \
    -o "$stage/ggml-base.bin"
  printf '%s  %s\n' "$model_hash" "$stage/ggml-base.bin" | shasum -a 256 --check
  mv "$stage/ggml-base.bin" "$destination/ggml-base.bin"
fi

printf 'Multilingual dictation is ready.\n'
