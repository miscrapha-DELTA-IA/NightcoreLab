#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
benchmark_dir="$(mktemp -d)"
trap 'rm -rf "$benchmark_dir"' EXIT
# Compile the ACTUAL scalar types and resolver. Exclude only the legacy
# program factory (depends on app UI vocabulary) and the unused target lookup.
python3 - "$benchmark_dir" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
root = Path('NightcoreLab/Sources')
def remove_block(text, marker):
    assert text.count(marker) == 1, marker
    start = text.index(marker)
    opening = text.index('{', start)
    level = 1
    end = opening + 1
    while level:
        level += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[:start] + text[end:]
material = (root/'Creative/VisualMaterial/VisualMaterial.swift').read_text()
(out/'VisualMaterial.swift').write_text(remove_block(material, '    static func marble(for program:'))
program = (root/'Creative/CreativeVisualProgram.swift').read_text()
frame = program[program.index('struct CreativeParameterFrame:'):program.index('enum CreativeParameterResolver')]
(out/'CreativeParameterFrame.swift').write_text('import Foundation\n' + remove_block(frame, '    func value(for target:'))
for name in ['MaterialResolver', 'MaterialFrame', 'VisualParameterSet', 'MaterialAudioMapping', 'VisualMaterialCatalog']:
    (out/f'{name}.swift').write_bytes((root/f'Creative/VisualMaterial/{name}.swift').read_bytes())
# The route decision is part of the resolver; the reaction gain needs the
# app's CreativePreset vocabulary and is passed in as a number here.
profile = (root/'Creative/CreativeReactionProfile.swift').read_text()
(out/'CreativeReactionProfile.swift').write_text(remove_block(profile, '    static func gain('))
for path in ['Creative/AudioFeatures.swift','MusicIntelligence/RhythmFrame.swift','MusicIntelligence/RhythmAnalysisResult.swift']:
    (out/Path(path).name).write_bytes((root/path).read_bytes())
PY
cp scripts/material-benchmark/main.swift "$benchmark_dir/main.swift"
xcrun clang -O2 -dynamiclib scripts/material-benchmark/allocations.c -o "$benchmark_dir/libMaterialAllocations.dylib"
xcrun swiftc -O -swift-version 5 "$benchmark_dir"/*.swift -L "$benchmark_dir" -lMaterialAllocations -Xlinker -rpath -Xlinker "$benchmark_dir" -o "$benchmark_dir/material-benchmark"
DYLD_INSERT_LIBRARIES="$benchmark_dir/libMaterialAllocations.dylib" "$benchmark_dir/material-benchmark"
