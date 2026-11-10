#!/usr/bin/env python3
"""Verify the parent application's models against its independently reviewed golden manifest."""
from pathlib import Path
import json
import os
import re
import subprocess
import sys
import tempfile
from test_codegen import ROOT, run, snapshot


def main():
    parent = Path(sys.argv[1]).resolve()
    roots = {
        'swift': parent / 'app-apple/Sources/CommonLibraryCore/Domain/Codegen',
        'kotlin': parent / 'app-android/app/src/main/kotlin/com/algoritmico/passepartout/models',
        'cpp': parent / 'app-cross/models',
    }
    golden = json.loads((parent / 'ci/codegen-golden.json').read_text())
    schema = (parent / 'scripts/openapi.yaml').read_text()
    with tempfile.TemporaryDirectory(prefix='parent-codegen-') as temp:
        tmp = Path(temp)
        binary = tmp / 'codegen'
        run('zig', 'build-exe', str(ROOT / 'tools/openapi_codegen.zig'),
            '-O', 'ReleaseSafe', '-femit-bin=' + str(binary), cwd=tmp)
        source = tmp / 'schema.yaml'
        source.write_text(schema)
        for lang, checked_in in roots.items():
            opts = ['--language', lang, '--external', 'ConnectionStatus,ModuleType,TaggedProfile']
            if lang == 'swift':
                opts += ['--swift-prefix', 'OpenAPI']
            else:
                opts += ['--package', 'Passepartout::Models' if lang == 'cpp' else 'com.algoritmico.passepartout.models']
            target = tmp / lang
            run(str(binary), str(source), str(target), *opts, cwd=tmp)
            assert snapshot(target) == golden[lang], f'{lang}: parent golden drift'
            assert snapshot(target) == snapshot(checked_in), f'{lang}: parent checked-in drift'
            repeated = tmp / (lang + '-repeat')
            run(str(binary), str(source), str(repeated), *opts, cwd=ROOT,
                env={**os.environ, 'LC_ALL': 'C', 'TZ': 'Pacific/Honolulu'})
            assert snapshot(repeated) == golden[lang], f'{lang}: nondeterministic output'
            prefix, body = schema.split('  schemas:\n', 1)
            body, suffix = body.split('\ninfo:', 1)
            blocks = re.split(r'(?=^    [^ ].*:\n)', body, flags=re.M)
            source.write_text(prefix + '  schemas:\n' + ''.join(
                b.rstrip('\n') + '\n' for b in reversed(blocks) if b) + '\ninfo:' + suffix)
            run(str(binary), str(source), str(repeated), *opts, cwd=tmp)
            assert snapshot(repeated) == golden[lang], f'{lang}: schema order changed output'
            source.write_text(schema.replace('            local:\n',
                '            regressionProbe:\n              type: boolean\n            local:\n', 1))
            run(str(binary), str(source), str(repeated), *opts, cwd=tmp)
            name = {'swift': 'OpenAPIAppConstantsContainers.swift',
                    'kotlin': 'AppConstantsContainers.kt', 'cpp': 'AppConstants_containers.h'}[lang]
            assert 'regressionProbe' in (repeated / name).read_text(), 'inline schema change ignored'
            source.write_text(schema.replace('            local:\n',
                '            local:\n              unsupportedConstraint: true\n', 1))
            failed = subprocess.run([str(binary), str(source), str(target), *opts], capture_output=True)
            assert failed.returncode != 0 and snapshot(target) == golden[lang]
            source.write_text(schema)

            # Verify the external-import/prefix public wrapper without Java or npm fallback.
            banned = tmp / 'banned-tools'
            banned.mkdir(exist_ok=True)
            for tool in ['openapi-generator', 'openapi-generator-cli', 'java', 'npm', 'npx', 'perl', 'ruby']:
                stub = banned / tool
                stub.write_text('#!/bin/sh\necho "Legacy tool invoked" >&2\nexit 99\n')
                stub.chmod(0o755)
            package = 'Passepartout.Models' if lang == 'cpp' else 'com.algoritmico.passepartout.models'
            wrapper_target = tmp / (lang + '-wrapper')
            command = [str(ROOT / 'scripts/gen-models.sh'), str(source), lang, str(wrapper_target), package,
                       'ConnectionStatus,ModuleType,TaggedProfile']
            if lang == 'swift':
                command += ['OpenAPI']
            run(*command, cwd=tmp, env={**os.environ, 'PATH': str(banned) + os.pathsep + os.environ['PATH']})
            models = wrapper_target / 'src/main/kotlin/com/algoritmico/passepartout/models' if lang == 'kotlin' else wrapper_target
            assert snapshot(models) == golden[lang], f'{lang}: wrapper differs'
            print(f'Parent {lang}: {len(golden[lang])} files match; repeatability and schema checks passed.', flush=True)


if __name__ == '__main__':
    main()
