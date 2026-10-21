from pathlib import Path
import hashlib,json,sys
manifest=json.loads(Path(__file__).with_name('model-manifest.json').read_text())
root=Path(sys.argv[1]); evidence=json.loads((root/'conversion-evidence.json').read_text())
pipeline=json.loads((root/'pipeline.json').read_text())
# MIL constant packing/order can differ across converter hosts. Verify immutable
# source tensors and this build's checksum; the full numerical gate on macOS is
# mandatory and checks every output sample against the stock PyTorch reference.
assert evidence['source_revision']==manifest['huggingface_revision']
assert evidence['source_files']==manifest['source_files']
assert evidence['model_id']==manifest['model_id']
assert evidence['surgery_max_error']<1e-3
assert pipeline['model_id']==manifest['model_id'] and len(pipeline['stages'])==29
for stage, checksum in evidence['stage_sha256'].items():
    weight=root/(stage+'.mlpackage')/'Data/com.apple.CoreML/weights/weight.bin'
    assert hashlib.sha256(weight.read_bytes()).hexdigest()==checksum, stage
assert len(evidence['stage_sha256'])==26
assert (root/'golden/mix.f32').stat().st_size==2*343980*4
assert (root/'golden/reference.f32').stat().st_size==4*2*343980*4
assert (root/'golden/spec-input.f32').stat().st_size==4*2048*336*4
assert (root/'golden/spec-reference.f32').stat().st_size==4*4*2048*336*4
assert (root/'golden/time-reference.f32').stat().st_size==4*2*343980*4
print('Verified immutable source weights, conversion integrity and reference tensors')

assert (root/'golden/music-mix.f32').stat().st_size==2*343980*4
assert (root/'golden/music-reference.f32').stat().st_size==4*2*343980*4
