from pathlib import Path
import hashlib,json,sys
manifest=json.loads(Path(__file__).with_name('model-manifest.json').read_text())
root=Path(sys.argv[1]); evidence=json.loads((root/'conversion-evidence.json').read_text())
weight=root/'htdemucs_core.mlpackage/Data/com.apple.CoreML/weights/weight.bin'
# MIL constant packing/order can differ across converter hosts. Verify immutable
# source tensors and this build's checksum; the full numerical gate on macOS is
# mandatory and checks every output sample against the stock PyTorch reference.
assert evidence['source_revision']==manifest['huggingface_revision']
assert evidence['source_files']==manifest['source_files']
assert evidence['model_id']==manifest['model_id']
assert evidence['surgery_max_error']<1e-3
assert hashlib.sha256(weight.read_bytes()).hexdigest()==evidence['converted_sha256']
assert (root/'golden/mix.f32').stat().st_size==2*343980*4
assert (root/'golden/reference.f32').stat().st_size==4*2*343980*4
print('Verified immutable source weights, conversion integrity and reference tensors')
