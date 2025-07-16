//
// MIT License
//
// Copyright (c) 2025 Davide De Rosa
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//

import { describe, it } from "mocha";
import { strict as assert } from "assert";
import * as setup from "../setup.js";

describe("mullvad", () => {
    let infra;
    before(() => {
        const json = setup.fetchMockInfrastructure("mullvad");
        infra = json.response;
    });
    it("should have 2 presets", () => {
        assert.strictEqual(infra.presets.length, 2);
    });
    it("should have 2 servers", () => {
        assert.strictEqual(infra.servers.length, 2);
    });
    it("preset 0 should use CBC and 9 endpoints", () => {
        const preset = infra.presets[0];
        assert.strictEqual(preset.moduleType, "OpenVPN");
        const template = setup.templateFrom(preset);
        const cfg = template.configuration;
        assert.strictEqual(cfg.cipher, "AES-256-CBC");
        assert.deepStrictEqual(template.endpoints, [
            "UDP:1194", "UDP:1195", "UDP:1196", "UDP:1197",
            "UDP:1300", "UDP:1301", "UDP:1302", "TCP:443", "TCP:80"
        ]);
    });
    it("preset 1 should use CBC and 2 endpoints", () => {
        const preset = infra.presets[1];
        assert.strictEqual(preset.moduleType, "OpenVPN");
        const template = setup.templateFrom(preset);
        const cfg = template.configuration;
        assert.strictEqual(cfg.cipher, "AES-256-CBC");
        assert.deepStrictEqual(template.endpoints, [
            "UDP:1400", "TCP:1401"
        ]);
    });
});
