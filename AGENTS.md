# Good practices

## General

- Make success the main function path, with early exit/return on failures.

## Zig

- Never ever use inline `@import` in normal code. Only use `@import` at the beginning of the file.
- Each subfolder in "src" is a module. A module must never import directly a file from another module unless it is "src/<module>/exports.zig".
- Never force unwrap an optional with `some.foobar.?` after `if (some.foobar == null) return;`. Instead, use `const foobar = some.foobar orelse return;`.

## C++

- Use PascalCase for all methods, public and private.
- Do not compress blocks, as in no text after curly braces or multiple semicolon-separated lines. However, one-liner like `if (condition) return;` are acceptable as long as they are not too long.
- Empty blocks in curly braces are fine (`{}`).
