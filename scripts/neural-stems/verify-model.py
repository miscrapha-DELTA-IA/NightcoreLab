from pathlib import Path
import hashlib,json,sys
manifest=json.loads(Path(__file__).with_name('model-manifest.json').read_text())
root=Path(sys.argv[1])
weight=root/'htdemucs_core.mlpackage/Data/com.apple.CoreML/weights/weight.bin'
assert hashlib.sha256(weight.read_bytes()).hexdigest()==manifest['weights_sha256'], 'Converted weights differ from pinned model'
assert (root/'golden/mix.f32').stat().st_size==2*343980*4
assert (root/'golden/reference.f32').stat().st_size==4*2*343980*4
print('Verified converted model weights and reference tensors')
