# Good practices

## General

- Make success the main function path, with early exit/return on failures.

## Zig

- Never ever use inline `@import` in normal code. Only use `@import` at the beginning of the file.
- Each subfolder in "src" is a module. A module must never import directly a file from another module unless it is "src/<module>/exports.zig".
- Never force unwrap an optional with `some.foobar.?` after `if (some.foobar == null) return;`. Instead, use `const foobar = some.foobar orelse return;`.

## Kotlin

- Never use fully qualified entities. Import the parent package, then use the entity unprefixed. The only exception is for disambiguation.
- When a function depends on API availability, make recent API the main path. Early exit when unavailable.

## C and C++

- Use `pp_free()` instead of direct `free()` calls wherever the Partout allocation helpers are available. Keep direct `free()` only inside the helper implementation or standalone code without those helpers.

## C++

- Declare concrete classes `final` by default. Use inheritance only from
  pure-virtual interfaces, UI classes, or exception classes (such as
  `std::exception` and `std::runtime_error`). Pure-virtual interfaces expose
  abstract operations and may have a default virtual destructor. Outside UI and
  exception hierarchies, do not inherit implementation; use composition instead.
  Leave UI and exception classes extensible only when they are intentional bases;
  do not leave classes open for
  hypothetical future subclasses. This rule applies to both `class` and `struct`.
  Apply changes to generated classes through their generator rather than editing
  generated output.

- Apply `PARTOUT_API` to individual out-of-line functions that cross the library
  boundary, not to entire classes or structs. Inline methods, pure virtual
  declarations, and data-only types do not need export annotations.
- Order `.cc` content after includes consistently: anonymous namespace helpers,
  then any necessary file-level `using` directives, then entity implementations. Keep
  helpers together rather than interleaving anonymous namespace blocks with
  implementations. Anonymous namespaces must be standalone at file scope, never
  nested inside a named namespace. Place them before file-level `using`
  directives and named entity implementations. Explicitly qualify references to
  project types and functions inside helpers; do not use a namespace-wide `using`
  directive there to recreate the enclosing namespace's lookup.
- Omit redundant `using namespace` directives. Names in the enclosing namespace
  are already visible, including in the parameters and body of a qualified
  function definition. Retain directives only where unqualified names need them,
  such as return types or class names before a qualified function's declarator.
- Use C++20 features only for designated initializers. Prefer clear, conventional pre-C++20 constructs and avoid obscure patterns.
- Use PascalCase for all methods, public and private, and named constants.
- Use snake_case for C++ variables, parameters, and data members. Preserve the
  trailing underscore convention for private data members (for example,
  `controller_options_`). Keep generated model identifiers and externally owned
  API/ABI names unchanged; follow their declared spelling at call sites.
- Use namespaces to express a function's domain instead of embedding domain or
  protocol names in long function names. For example, use
  `Partout::OpenVPN::PrepareInteractiveProfile`, not
  `Partout::PrepareOpenVPNInteractiveProfile`. Keep related helper types in the
  same namespace without repeating its name (for example, `OpenVPN::CredentialPrompt`).
- Use four spaces per indentation level, never tabs. Do not add indentation for
  named or anonymous namespaces, `extern "C"` linkage wrappers, or `__cplusplus`
  compatibility guards; keep their contents at the surrounding indentation level.
  Indent function, class, and control-flow bodies normally. Align closing braces
  with their opening declaration. Align access labels with the class declaration
  and indent members one level further. For wrapped parameter lists,
  align continuation parameters with the first parameter or place all parameters
  on separate lines indented one level; never leave stale alignment after edits.
- When a function parameter or call argument list spans multiple lines, put its
  closing `)` on a new line aligned with the start of the declaration or call.
  Keep trailing syntax such as `;`, `const`, or `{` after that `)`.
- Do not compress blocks, as in no text after curly braces or multiple semicolon-separated lines. However, one-liner like `if (condition) return;` are acceptable as long as they are not too long.
- Empty blocks in curly braces are fine (`{}`).
- Add a blank line only between adjacent function, type, or namespace definitions,
  including inline member definitions. Do not add blank lines solely because a
  block ends with a closing brace; this rule does not apply between statements,
  control-flow blocks, or nested closing braces.
- Keep JSON library knowledge inside model codec implementations and the shared
  `Partout::Json` wrapper. Consumer code must use model APIs and the wrapper,
  including its error type, rather than nlohmann types or operations. Change generated
  model APIs through the shared generator, never by editing generated files.
