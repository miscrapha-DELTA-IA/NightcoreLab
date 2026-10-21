#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
model_cache=${GNARLY_MODEL_CACHE:-"$repo_root/.cache/gnarly-neural-model"}
mkdir -p "$model_cache"
python3 "$script_dir/verify-model.py" "$model_cache"
rm -rf "$model_cache/htdemucs_staged"
mkdir -p "$model_cache/htdemucs_staged"
for package in "$model_cache"/*.mlpackage; do
  xcrun coremlcompiler compile "$package" "$model_cache/htdemucs_staged"
done
cp "$model_cache/pipeline.json" "$model_cache/htdemucs_staged/"
cd "$repo_root"
swift test -c release
swift run -c release NeuralStemGate "$model_cache"
swift run -c release NeuralStemGate "$model_cache" --cpu-only
model_dest="$repo_root/NightcoreLab/Resources/NeuralStems"
mkdir -p "$model_dest"
rm -rf "$model_dest/htdemucs_core.mlmodelc" "$model_dest/htdemucs_staged"
cp -R "$model_cache/htdemucs_staged" "$model_dest/"
cp "$model_cache"/neural-parity*.json "$model_dest/"
cp "$script_dir/model-manifest.json" "$model_dest/"
