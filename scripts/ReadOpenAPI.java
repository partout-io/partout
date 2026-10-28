// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.Reader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import org.yaml.snakeyaml.LoaderOptions;
import org.yaml.snakeyaml.Yaml;
import org.yaml.snakeyaml.constructor.SafeConstructor;

// Use the YAML and JSON libraries already bundled in the required generator JAR.
// Read the original document directly: the generator's OpenAPI export normalizes
// schemas and can discard type/const metadata before our projection sees it.
class ReadOpenAPI {
    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            throw new IllegalArgumentException("Expected input YAML and output JSON paths");
        }
        LoaderOptions options = new LoaderOptions();
        options.setAllowDuplicateKeys(false);
        Object document;
        try (Reader input = Files.newBufferedReader(Path.of(args[0]), StandardCharsets.UTF_8)) {
            document = new Yaml(new SafeConstructor(options)).load(input);
        }
        if (!(document instanceof Map)) {
            throw new IllegalArgumentException("Expected an OpenAPI document object");
        }
        new ObjectMapper().writeValue(Path.of(args[1]).toFile(), document);
    }
}
