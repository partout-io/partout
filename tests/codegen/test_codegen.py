#!/usr/bin/env python3
"""Byte parity, repeatability, schema sensitivity and failure safety (stdlib only)."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MODELS = {
    'swift': ROOT / 'cross/apple/Sources/PartoutCore/OpenAPI/Codegen',
    'kotlin': ROOT / 'cross/android/src/io/partout/models',
    'cpp': ROOT / 'cross/cpp/models',
}


def snapshot(directory):
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(directory.iterdir()) if p.is_file()}


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    golden = json.loads(Path(__file__).with_name('golden.json').read_text())
    schema = (ROOT / 'scripts/openapi.yaml').read_text()
    with tempfile.TemporaryDirectory(prefix='partout-codegen-test-') as tmp:
        tmp = Path(tmp)
        binary = tmp / 'codegen'
        run('zig', 'build-exe', str(ROOT / 'tools/openapi_codegen.zig'),
            '-O', 'ReleaseSafe', '-femit-bin=' + str(binary), cwd=tmp)
        schema_file = tmp / 'schema.yaml'
        schema_file.write_text(schema)
        excludes_block = (ROOT / 'build.zig').read_text().split('const default_api_excluded_schemas =', 1)[1].split(';', 1)[0]
        excludes = ''.join(re.findall(r'"([^"\n]*)"', excludes_block))
        zig_output = tmp / 'api_generated.zig'
        run(str(binary), str(schema_file), str(zig_output), '--exclude', excludes, cwd=tmp)
        assert zig_output.read_bytes() == (ROOT / 'src/core/api_generated.zig').read_bytes(), 'Zig model regression'
        print('Zig: existing output unchanged', flush=True)
        for language, models in MODELS.items():
            first, second = tmp / language, tmp / (language + '-repeat')
            run(str(binary), str(schema_file), str(first), '--language', language, cwd=tmp)
            # A different working directory, locale, timezone and output path must not matter.
            run(str(binary), str(schema_file), str(second), '--language', language,
                cwd=ROOT, env={**os.environ, 'TZ': 'Pacific/Honolulu', 'LC_ALL': 'C'})
            actual = snapshot(first)
            assert actual == snapshot(second), f'{language}: nondeterministic output'
            assert actual == snapshot(models), f'{language}: checked-in model drift'
            assert actual == golden[language], f'{language}: golden compatibility drift'
            print(f'{language}: {len(actual)} files match byte for byte', flush=True)

            # Adding a property must affect schema-derived output, never replay a snapshot.
            changed = schema.replace(
                '      properties:\n', '      properties:\n        regressionProbe:\n          type: boolean\n', 1)
            schema_file.write_text(changed)
            mutated = tmp / (language + '-mutated')
            run(str(binary), str(schema_file), str(mutated), '--language', language, cwd=tmp)
            extension = {'swift': 'swift', 'kotlin': 'kt', 'cpp': 'h'}[language]
            assert 'regressionProbe' in (mutated / ('ABIEnvelope.' + extension)).read_text()
            assert snapshot(mutated) != actual
            schema_file.write_text(schema)

            # Reordering schema declarations must not change files or their contents.
            prefix, body = schema.split('  schemas:\n', 1)
            body, suffix = body.split('\ninfo:', 1)
            blocks = re.split(r'(?=^    [^ ].*:\n)', body, flags=re.M)
            reordered = prefix + '  schemas:\n' + ''.join(b.rstrip('\n') + '\n' for b in reversed(blocks) if b) + '\ninfo:' + suffix
            schema_file.write_text(reordered)
            shuffled = tmp / (language + '-shuffled')
            run(str(binary), str(schema_file), str(shuffled), '--language', language, cwd=tmp)
            assert snapshot(shuffled) == actual, f'{language}: declaration order leaked into output'
            schema_file.write_text(schema)

        for invalid in (
            schema.replace('          type: boolean', '          type: imaginary', 1),
            schema.replace('          type: boolean', '          type: boolean\n          nullable: true', 1),
            schema.replace('#/components/schemas/PartoutErrorCode', '#/components/schemas/Missing', 1),
            schema.replace('    ABIEnvelope:', '    ../ABIEnvelope:', 1),
            schema.replace('          type: boolean', '          type: boolean\n          type: string', 1),
            schema.replace('          type: boolean', '          type: boolean\n            minimum: 0', 1),
            schema.replace('      additionalProperties: false', '      additionalProperties: true', 1),
            schema.replace('      description: A hostname or IP address.', '      description: |\n        unsupported block scalar', 1),
        ):
            schema_file.write_text(invalid)
            for language in MODELS:
                target = tmp / language
                before = snapshot(target)
                failed = subprocess.run([str(binary), str(schema_file), str(target), '--language', language],
                                        cwd=tmp, capture_output=True)
                assert failed.returncode != 0, f'{language}: invalid schema accepted'
                assert snapshot(target) == before, f'{language}: invalid schema changed output'
        schema_file.write_text(schema)

        # Exercise the public wrapper, including Kotlin's historical directory layout.
        for language in MODELS:
            target = tmp / ('wrapper-' + language)
            package = 'Partout.Models' if language == 'cpp' else 'io.partout.models'
            command = [str(ROOT / 'scripts/gen-models.sh'), str(schema_file), language, str(target), package]
            run(*command, cwd=tmp)
            models = target / 'src/main/kotlin/io/partout/models' if language == 'kotlin' else target
            assert snapshot(models) == golden[language]
            (models / 'stale-file').write_text('stale')
            run(*command, cwd=tmp)
            assert snapshot(models) == golden[language], 'stale generated file survived'
            schema_file.write_text(schema.replace('          type: boolean', '          type: imaginary', 1))
            failed = subprocess.run(command, cwd=tmp, capture_output=True)
            assert failed.returncode != 0
            assert snapshot(models) == golden[language], 'wrapper lost last good models'
            schema_file.write_text(schema)
    print('Parity, repeatability, schema sensitivity and failure safety passed.', flush=True)


if __name__ == '__main__':
    main()
