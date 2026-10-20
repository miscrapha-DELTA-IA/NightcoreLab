#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
model_cache=${GNARLY_MODEL_CACHE:-"$repo_root/.cache/gnarly-neural-model"}
mkdir -p "$model_cache"
model_repo=${GNARLY_MODEL_REPO:-miscrapha-DELTA-IA/NightcoreLab}
model_tag=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["release"])' "$script_dir/model-manifest.json")
model_asset=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["asset"])' "$script_dir/model-manifest.json")
if [ ! -f "$model_cache/$model_asset" ]; then
    gh release download "$model_tag" --repo "$model_repo" --pattern "$model_asset" --dir "$model_cache"
fi
python3 - "$script_dir/model-manifest.json" "$model_cache" <<'PY'
import hashlib,json,sys,zipfile
from pathlib import Path
manifest=json.loads(Path(sys.argv[1]).read_text()); root=Path(sys.argv[2])
archive=root/manifest['asset']
if hashlib.sha256(archive.read_bytes()).hexdigest()!=manifest['sha256']:
    archive.unlink(missing_ok=True)
    raise SystemExit('Neural model archive checksum mismatch; refusing to build')
with zipfile.ZipFile(archive) as z:
    for name in z.namelist():
        path=Path(name)
        if path.is_absolute() or '..' in path.parts: raise SystemExit('Invalid archive path')
    z.extractall(root)
print('Verified HTDemucs model archive')
PY
rm -rf "$model_cache/htdemucs_core.mlmodelc"
xcrun coremlcompiler compile "$model_cache/htdemucs_core.mlpackage" "$model_cache"
cd "$repo_root"
swift run -c release NeuralStemGate "$model_cache"
model_dest="$repo_root/NightcoreLab/Resources/NeuralStems"
mkdir -p "$model_dest"
rm -rf "$model_dest/htdemucs_core.mlmodelc"
cp -R "$model_cache/htdemucs_core.mlmodelc" "$model_dest/"
cp "$model_cache/neural-parity.json" "$model_dest/"
cp "$script_dir/model-manifest.json" "$model_dest/"
