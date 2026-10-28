#!/usr/bin/env python3
"""Apply naming and generic JSON integration fixes to stock generator output.

Discriminator selection is emitted entirely by cpp-httplib-server. This pass
neither reads discriminator mappings nor emits dispatch branches.
"""
from pathlib import Path
import json
import re
import sys


schemas = json.loads(Path(sys.argv[2]).read_text())["components"]["schemas"]


def repair_decoder(match, source):
    name = match.group(1)
    start = match.end()
    depth = 1
    end = start
    for token in re.finditer(r'"(?:\\.|[^"\\])*"|[{}]', source[start:]):
        if token.group(0) == "{":
            depth += 1
        elif token.group(0) == "}":
            depth -= 1
            if depth == 0:
                end = start + token.start()
                break
    if depth:
        raise ValueError(f"{name}: unmatched decoder braces")
    body = source[start:end]
    body = re.sub(r"\bo\.", "parsed.", body)
    # Numeric enum decoders also need checked conversion.
    body = re.sub(r"auto s = j.get<(int(?:32|64)_t)>\(\);",
                  r"\1 s;\n    ReadJsonValue(j, s);", body)
    check = ""
    if schemas[name].get("type") == "object":
        check = f'\n    if (!j.is_object()) throw std::invalid_argument("Expected {name} object");'
    for field, property_schema in schemas[name].get("properties", {}).items():
        if "const" in property_schema:
            literal = json.dumps(property_schema["const"])
            check += (f'\n    if (j.at("{field}") != {literal}) '
                      f'throw std::invalid_argument("Invalid constant field {field} in {name}");')
    replacement = check + f"\n    {name} parsed{{}};" + body + "    o = std::move(parsed);\n"
    return source[:start] + replacement + source[end:]


for path in Path(sys.argv[1]).iterdir():
    if path.suffix not in (".h", ".cpp"):
        continue
    source = path.read_text()
    source = source.replace('#include <nlohmann/json.hpp>', '#include "../json.h"')
    source = re.sub(r"\bvalidate\(", "Validate(", source)
    source = source.replace("to_json()", "ToJson()")
    source = source.replace("from_json(const nlohmann::json& j)",
                            "FromJson(const nlohmann::json& j)")
    # A union is a std::variant, so recursive validation needs a generic visitor
    # rather than a model member function. Ordinary model validation is unchanged.
    source = re.sub(r"\b([\w.]+)\.Validate\(", r"ValidateModel(\1, ", source)
    # Preserve strict numeric conversion before nlohmann can truncate/wrap it.
    source = re.sub(r'j\.at\("([^"\n]+)"\)\.get_to\(([^;\n]+)\);',
                    r'ReadJsonValue(j.at("\1"), \2);', source)

    def optional_null(match):
        key, field_type = match.group(1), match.group(2).strip()
        if field_type == "nlohmann::json":
            return match.group(0)  # null is itself a valid raw JSON payload
        return match.group(0).replace(' != j.end())',
            f' != j.end() && !j.at("{key}").is_null())')

    source = re.sub(r'if \(j.find\("([^"\n]+)"\) != j.end\(\)\) \{\n\s*([^;\n]+) temporary_\w+;',
                    optional_null, source)
    # Stock value structs do not apply OAS 3.1 const defaults. Enforce those
    # schema assertions generically; the generated union still selects branches.
    for field, property_schema in schemas.get(path.stem, {}).get("properties", {}).items():
        if "const" not in property_schema:
            continue
        literal = json.dumps(property_schema["const"])
        if path.suffix == ".h":
            source, count = re.subn(rf"^( +)([^;\n]+) {re.escape(field)};",
                rf"\1\2 {field} = {literal};", source, flags=re.M)
            if count != 1:
                raise ValueError(f"{path.name}: expected one constant field {field}")
        else:
            signature = f"void to_json(nlohmann::json& j, const {path.stem}& o)\n{{"
            check = (f'\n    if (o.{field} != {literal}) '
                     f'throw std::invalid_argument("Invalid constant field {field} in {path.stem}");')
            source = source.replace(signature, signature + check)
    if path.suffix == ".cpp":
        decoders = list(re.finditer(r"void from_json\(const nlohmann::json& j, (\w+)& o\)\n\{", source))
        for decoder in reversed(decoders):
            source = repair_decoder(decoder, source)
    source = re.sub(r"[ \t]+$", "", source, flags=re.M)
    source = re.sub(r"\n{3,}", "\n\n", source)
    path.write_text(source)
