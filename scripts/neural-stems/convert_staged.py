#!/usr/bin/env python3
"""Convert pinned full-fp32 HTDemucs into independently releasable stages."""
import argparse
import gc
import hashlib
import json
from pathlib import Path
import numpy as np
import torch
from huggingface_hub import hf_hub_download
from demucs.hf import load_safetensors_model
import demucs.hdemucs as hd
import demucs.htdemucs as htd
import stemcommon as sc
from staged_core import stages
from musical_fixture import musical_mix


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--resume-conversion', action='store_true')
    args = parser.parse_args()
    root = args.output
    root.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(2)
    hd.pad1d = htd.pad1d = sc.pad1d_safe
    manifest = json.loads(Path(__file__).with_name('model-manifest.json').read_text())
    revision = manifest['huggingface_revision']
    checkpoint = Path(hf_hub_download(manifest['huggingface_repo'], '955717e8.safetensors', revision=revision))
    assert hashlib.sha256(checkpoint.read_bytes()).hexdigest() == manifest['source_files']['955717e8.safetensors']
    config = Path(hf_hub_download(manifest['huggingface_repo'], 'htdemucs.yaml', revision=revision))
    assert hashlib.sha256(config.read_bytes()).hexdigest() == manifest['source_files']['htdemucs.yaml']
    model = load_safetensors_model(str(checkpoint)).eval()
    assert model.sources == ['drums', 'bass', 'other', 'vocals']
    torch.manual_seed(7)
    mix = torch.randn(1, 2, sc.SEG_SAMPLES) * .1
    with torch.no_grad():
        spectrum = sc.magnitude_cac(sc.spec(mix))
        instructions, modules, frequency, time = stages(model, mix, spectrum)
        actual = sc.ispec(sc.mask_cac(frequency), sc.SEG_SAMPLES) + time
        reference = model(mix)
    error = float((actual - reference).abs().max())
    print('Staged + globally tiled attention vs stock max error:', error, flush=True)
    assert error < 1e-5, 'Model surgery changed separation'
    fixtures = root / 'golden'
    fixtures.mkdir(exist_ok=True)
    for name, tensor in [('mix', mix), ('reference', reference), ('spec-input', spectrum),
                         ('spec-reference', frequency), ('time-reference', time)]:
        tensor.numpy().tofile(fixtures / (name + '.f32'))
    with torch.no_grad():
        music = musical_mix()
        music_reference = model(music)
    music.numpy().tofile(fixtures / 'music-mix.f32')
    music_reference.numpy().tofile(fixtures / 'music-reference.f32')
    del music, music_reference
    import coremltools as ct
    hashes = {}
    for instruction, module, inputs in modules:
        name = instruction['name']
        package = root / (name + '.mlpackage')
        if args.resume_conversion and package.exists():
            spec = ct.utils.load_spec(str(package))
            assert spec.description.metadata.userDefined['gnarly.model_id'] == manifest['model_id']
            weight = package / 'Data/com.apple.CoreML/weights/weight.bin'
            hashes[name] = hashlib.sha256(weight.read_bytes()).hexdigest()
            print('Reusing local prototype stage', name, flush=True)
            continue
        print('Converting', name, flush=True)
        # Unused inputs (e.g. decoder stats before the last layer) are omitted
        # by torch.export. Inspect the graph signature and map back to logical
        # tensor keys rather than passing an unused/misnamed input at runtime.
        with torch.no_grad():
            exported = torch.export.export(module, inputs, strict=False).run_decompositions({})
        user_inputs = [spec for spec in exported.graph_signature.input_specs if spec.kind.name == 'USER_INPUT']
        placeholders = {node.name: node for node in exported.graph.nodes if node.op == 'placeholder'}
        used = []
        for index, spec in enumerate(user_inputs):
            if placeholders[spec.arg.name].users:
                used.append(index)
        # Conversion's declared inputs must still cover the exported signature;
        # Core ML removes dead placeholders itself. Runtime uses descriptions.
        converted = ct.convert(exported, minimum_deployment_target=ct.target.iOS18,
                               compute_precision=ct.precision.FLOAT32, convert_to='mlprogram',
                               inputs=[ct.TensorType(name=f'input_{i}', shape=tuple(tensor.shape), dtype=np.float32)
                                       for i, tensor in enumerate(inputs)],
                               outputs=[ct.TensorType(name=f'output_{i}', dtype=np.float32)
                                        for i in range(len(instruction['outputs']))])
        converted.author = 'Meta Platforms, Inc.; Gnarly memory-bounded Core ML port'
        converted.license = 'MIT'
        converted.user_defined_metadata['gnarly.model_id'] = manifest['model_id']
        converted.user_defined_metadata['gnarly.stage'] = name
        converted.user_defined_metadata['segment_samples'] = str(sc.SEG_SAMPLES)
        package = root / (name + '.mlpackage')
        converted.save(str(package))
        weight = package / 'Data/com.apple.CoreML/weights/weight.bin'
        hashes[name] = hashlib.sha256(weight.read_bytes()).hexdigest()
        del exported, converted
        gc.collect()
    pipeline = {'model_id': manifest['model_id'], 'sources': model.sources,
                'segment_samples': sc.SEG_SAMPLES, 'attention_query_block': 64,
                'stage_headroom_bytes': 256 * 1024 * 1024, 'stages': instructions}
    (root / 'pipeline.json').write_text(json.dumps(pipeline, indent=2))
    evidence = {'model_id': manifest['model_id'], 'source_revision': revision,
                'source_files': manifest['source_files'], 'surgery_max_error': error,
                'stage_sha256': hashes}
    (root / 'conversion-evidence.json').write_text(json.dumps(evidence, indent=2))
    print('Converted', len(hashes), 'independent full-precision models; Core ML runtime gate required', flush=True)


if __name__ == '__main__':
    main()
