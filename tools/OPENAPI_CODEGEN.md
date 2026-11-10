# OpenAPI model generation

`openapi_codegen.zig` now generates Partout's Zig, Swift, Kotlin, and C++ models.
The first native-backend revision reproduces the checked-in 65 Swift files,
69 Kotlin files, and 136 C++ files byte for byte. No generated model changed in
this migration. The existing Zig interface and output remain unchanged.

## Analysis and migration boundary

Sharing the schema reader removes Java, OpenAPI Generator, Python, Perl, and
postprocessing from **Partout's native-model generation path**. Zig is its only
runtime tool dependency. Renderers derive declarations, properties, enum values,
discriminator branches, and serialization from the schema; they do not read the
checked-in model directories. Embedded templates contain reusable boilerplate
and the existing schema-independent C++ validation helpers.

The tradeoff is ownership of language-specific APIs and serialization behavior.
The old backends disagree on naming, constructor order, inheritance, imports,
sets, and documentation. A broad "equivalent code" rewrite would obscure those
changes. Byte parity makes this first migration reviewable, but deliberately
preserves some undesirable output. It is a compatibility milestone, not proof
that every historical behavior is ideal.

The parent Passepartout app uses the same executable with external type mappings
and the `OpenAPI` Swift prefix. The native reader handles its inline objects,
arrays of inline objects, typed maps, optional nullable scalars, UUID/byte formats,
integer defaults,
and indentless YAML sequences. The legacy shell/Java/Python pipeline and both
repositories' OpenAPI Generator manifests have been removed. No Java, npm,
Python, Perl, or Ruby is needed for generation; Python is used only for checks.

Parent model parity is guarded by its `ci/codegen-golden.json`. Four handwritten
Swift `Identifiable` conformances were moved from generated files into
`Domain/Extensions/Codegen+Identifiable.swift`; their APIs remain unchanged.
The stale `Issue.required` entry `providerLastUpdates` was removed from the parent
schema because no such property exists. All remaining parent model bytes match
the old output.

## Commands

The existing commands now use the native generator:

```sh
scripts/build.sh -gen-models all
scripts/build.sh -gen-models swift
scripts/build.sh -gen-models kotlin
scripts/build.sh -gen-models cpp
```

The public wrapper preserves the Kotlin package directory layout. It renders
into a sibling staging directory, then replaces the generated model directory.
Unsupported input leaves the last good directory untouched. Stale files are
removed on a successful replacement; unrelated Kotlin package files remain.

The underlying executable is useful for isolated generation into a fresh
output directory:

```sh
zig run tools/openapi_codegen.zig -- scripts/openapi.yaml /tmp/swift-models --language swift
zig run tools/openapi_codegen.zig -- scripts/openapi.yaml /tmp/kotlin-models --language kotlin --package io.partout.models
zig run tools/openapi_codegen.zig -- scripts/openapi.yaml /tmp/cpp-models --language cpp --package Partout::Models
zig build gen-api
```

The wrapper accepts optional external schema names as its fifth argument and a
Swift model prefix as its sixth. The executable exposes `--external` and
`--swift-prefix` for the same settings. External types use Partout imports and
C++ namespaces; generated types use the requested package.

Use the wrapper when replacing an existing model directory. The executable
renders and validates all files before writing but does not remove unrelated
files or promise an atomic multi-file filesystem transaction.

## Supported input and determinism

This is a generator for the repository's schema dialect, not a general YAML or
OpenAPI implementation. It supports canonical two-space block YAML, local
schema references, object properties, required fields, string/integer enums
with `x-enum-varnames`, descriptions, primitive aliases, arrays/sets, typed maps, inline objects, optional nullable scalars, integer defaults, and the
repository's single-parent discriminator/constant convention.
Native validation rejects unsupported schema keywords, unknown references, unsupported formats, duplicate declarations, malformed identifiers,
and filename collisions before writing. Extending the schema dialect requires
extending validation and tests together. The original Zig parsing behavior is
kept separate from native validation.

Output has no timestamps, absolute paths, environment-dependent headers, or
runtime hash-map iteration. Property and enum order follow the schema. Kotlin
stably groups required properties before optional properties. Imports and C++
union variants have explicit ordering rules. C++'s historical import bucket
order is emulated directly, independent of the host or Java runtime.

## Regression checks

```sh
zig test tools/openapi_codegen.zig
python3 tests/codegen/test_codegen.py
# When the parent repository is available:
python3 tests/codegen/test_parent_codegen.py ..
```

The Python check uses only the standard library and Zig. CI runs it in the Zig
job. It verifies:

- Existing Zig output is unchanged with the build's configured exclusions.
- Every native filename and byte matches both checked-in models and the frozen
  SHA-256 manifest in `tests/codegen/golden.json`.
- Repeated generation across directories, locales, and timezones is identical.
- Reordering schema declarations leaves every output file identical.
- Adding a schema property changes generated declarations in all three languages.
- Invalid inputs fail without changing previous output.
- The public wrapper preserves layouts, replaces stale generated files, and
  retains last-good models on generation failure.

The hashes are a review guard, not a substitute for serialization tests. For an
intentional schema/API change, review the generated diff and update only the
corresponding manifest entries in the same change. Never regenerate the manifest
merely to make an unexplained failure pass. The portable C++ serialization tests
remain in `tests/c/windows/models.cc`; Apple and Android retain their existing
language test suites.

## Retained quirks: remove after parity

Compatibility-only branches are marked `PARITY` in the renderer and wrapper.
All embedded boilerplate under `openapi_templates/` is also parity-preserved.
These are explicit follow-up work, not conventions for new handwritten code:

| Retained behavior | Later cleanup and compatibility implications |
| --- | --- |
| Old generator attribution, spacing, redundant imports, unused suppressions and validation locals | Replace headers and normalize formatting in a separately reviewed output-only change. |
| Swift `ModelUInt16/32/64`, inline `ModelType`, `httpproxy`, and existing external type mappings | Review public API names and handwritten extensions before renaming. |
| Missing Swift/Kotlin descriptions on inheritance children | Restore schema descriptions. |
| Swift blank line removed on structs containing sets | Normalize struct formatting after golden parity is retired. |
| Kotlin lowercase discriminator suffixes and backticks around soft keywords | Review source compatibility before conventionalizing names. |
| Kotlin required-first property order and contextual enum annotations, including container elements | Review constructor and serialization compatibility before changing. |
| HTML entities in Kotlin enum documentation and C++ schema documentation | Emit plain documentation with language-appropriate comment escaping. |
| C++ `OpenVpn`/`Dns`/`Ip` spellings and `interface_` field | Coordinate public header/API consumers before renaming. |
| C++ Java-style include bucket order, duplicate JSON includes, and last-child union imports | Sort and deduplicate imports; drop unused union imports. |
| C++ legacy validation checks arrays but omits scalar model recursion and repeats array field paths | Fix with explicit behavioral tests and release notes; never mix this with the generator swap. |
| C++ enum invalid sentinel/default serialization, uninitialized required primitive fields, and generated brace/indentation style | Review defaults and error behavior, then bring formatting into line with repository C++ conventions. |
| C++ helper names, obsolete date validators, and broad support includes | Trim and rename with caller/build coverage; the helpers are copied as reusable support templates for parity. |
| Parent Swift explicit encoders, fixed event tags, prefixing, scalar-alias documentation and HTML entities | Keep tag invariants; simplify redundant encoders and documentation only with output/API review. |
| C++ inline-object underscore names and lack of generated object checks; ignored property defaults | Preserve for parity, then review validation/default semantics with behavioral tests. |
| Parent C++ union headers include all child dependencies, while Partout unions retain the last-child leak | Deduplicate and trim in a separately reviewed formatting/import cleanup. |

Checked numeric conversion, typed-null handling, raw JSON null preservation,
constant checks, transactional decoding, and discriminator rejection are
intentional runtime guarantees. They are not cleanup quirks.
