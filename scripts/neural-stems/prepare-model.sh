#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
model_cache=${GNARLY_MODEL_CACHE:-"$repo_root/.cache/gnarly-neural-model"}
mkdir -p "$model_cache"
python3 "$script_dir/verify-model.py" "$model_cache"
rm -rf "$model_cache/htdemucs_core.mlmodelc"
xcrun coremlcompiler compile "$model_cache/htdemucs_core.mlpackage" "$model_cache"
cd "$repo_root"
swift test -c release --filter DemucsDSPTests
swift run -c release NeuralStemGate "$model_cache"
model_dest="$repo_root/NightcoreLab/Resources/NeuralStems"
mkdir -p "$model_dest"
rm -rf "$model_dest/htdemucs_core.mlmodelc"
cp -R "$model_cache/htdemucs_core.mlmodelc" "$model_dest/"
cp "$model_cache/neural-parity.json" "$model_dest/"
cp "$script_dir/model-manifest.json" "$model_dest/"
