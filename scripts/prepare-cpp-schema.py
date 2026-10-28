#!/usr/bin/env python3
"""Normalize the C++ generator input without changing the shared wire schema."""
import copy
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def generator_jar():
    configured = os.environ.get("OPENAPI_GENERATOR_JAR")
    if configured:
        jar = Path(configured).expanduser().resolve()
        if not jar.is_file():
            raise FileNotFoundError(f"OpenAPI Generator JAR does not exist: {jar}")
        return jar

    # Packaged launchers such as Homebrew's expose the existing JAR in -jar.
    # Never evaluate the launcher: only accept a literal path to an existing file.
    launcher = shutil.which("openapi-generator")
    if launcher:
        command = Path(launcher).resolve().read_text(errors="replace")
        match = re.search(r"-jar\s+(?:\"([^\"]+)\"|'([^']+)'|([^\s;]+))", command)
        if match:
            literal = next(group for group in match.groups() if group is not None)
            if not any(marker in literal for marker in ("$", "`", "%")):
                jar = Path(literal)
                if jar.is_absolute() and jar.is_file():
                    return jar
    raise RuntimeError("Set OPENAPI_GENERATOR_JAR to the installed generator CLI JAR")


def read_document(path):
    java_home = os.environ.get("JAVA_HOME")
    java = str(Path(java_home) / "bin" / "java") if java_home else "java"
    with tempfile.TemporaryDirectory(prefix="partout-openapi-") as temporary:
        output = Path(temporary) / "openapi.json"
        subprocess.run([java, "--class-path", str(generator_jar()),
                        str(Path(__file__).with_name("ReadOpenAPI.java")),
                        str(path), str(output)], check=True)
        return json.loads(output.read_text(encoding="utf-8"))


def cpp_name(name):
    # Use identifiers on which both stock C++ backends agree. In particular,
    # httplib's raw discriminator references must equal its generated filenames.
    name = name.replace(".", "_")
    while True:
        words = re.split(r"[_\-\s]+", re.sub(r"([a-z])([A-Z])", r"\1 \2", name))
        normalized = "".join(word if word[0].isupper() and not word.isupper()
                             else word.capitalize() for word in words if word)
        if normalized == name:
            return name
        name = normalized


def prepare(document):
    schemas = document["components"]["schemas"]
    unions = []
    for name, base in schemas.items():
        mapping = base.get("discriminator", {}).get("mapping", {})
        if not mapping:
            continue
        if "oneOf" in base or "anyOf" in base:
            raise ValueError(f"{name}: expected an inheritance discriminator")
        unions.append(name)
        base["oneOf"] = [{"$ref": reference} for reference in mapping.values()]
        for reference in mapping.values():
            child = schemas[reference.rsplit("/", 1)[1]]
            for field, schema in base.get("properties", {}).items():
                child.setdefault("properties", {}).setdefault(field, copy.deepcopy(schema))
            child["required"] = list(dict.fromkeys(
                base.get("required", []) + child.get("required", [])))
            parents = [parent for parent in child.get("allOf", [])
                       if parent.get("$ref") != f"#/components/schemas/{name}"]
            if parents:
                child["allOf"] = parents
            else:
                child.pop("allOf", None)

    # The ABI's named JSON bridge carries arrays and scalars as well as objects.
    schemas["JSONValue"] = {}
    names = {name: cpp_name(name) for name in schemas}
    names["Profile"] = "TaggedProfile"
    if len(set(names.values())) != len(names):
        raise ValueError("C++ schema names collide after normalization")

    def rewrite(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if isinstance(child, str) and child.startswith("#/components/schemas/"):
                    value[key] = "#/components/schemas/" + names[child.rsplit("/", 1)[1]]
                else:
                    rewrite(child)
        elif isinstance(value, list):
            for child in value:
                rewrite(child)

    rewrite(document)
    document["components"]["schemas"] = {names[name]: schema for name, schema in schemas.items()}
    return document, [names[name] for name in unions]


if __name__ == "__main__":
    document, unions = prepare(read_document(sys.argv[1]))
    with open(sys.argv[2], "w", encoding="utf-8") as output:
        json.dump(document, output, indent=2)
        output.write("\n")
    with open(sys.argv[3], "w", encoding="utf-8") as output:
        output.write(":".join(unions) + "\n")
