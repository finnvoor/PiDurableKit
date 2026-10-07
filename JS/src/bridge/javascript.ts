// JavaScript extensions: pi-durable extensions written in JavaScript, evaluated in the harness's runtime and installed
// unchanged, exactly as a Node app would install its own. Like pi-durable, there is no sandbox: install only code you
// trust.
import * as chordContext from "@earendil-works/chord/context";
import * as piAI from "@earendil-works/pi-ai";
import * as piDurable from "@earendil-works/pi-durable";
import * as piDurableEnv from "@earendil-works/pi-durable/env";
import * as piDurableTools from "@earendil-works/pi-durable/tools";
import type { Extension } from "@earendil-works/pi-durable";

/** The packages an extension may `require`. */
const modules: Record<string, unknown> = {
	"@earendil-works/pi-durable": piDurable,
	"@earendil-works/pi-durable/tools": piDurableTools,
	"@earendil-works/pi-durable/env": piDurableEnv,
	"@earendil-works/pi-ai": piAI,
	"@earendil-works/chord/context": chordContext,
};

/**
 * Evaluates a CommonJS module whose `module.exports` (or `exports.default`) is a pi-durable extension:
 *
 * ```js
 * const { defineExtension, defineTool } = require("@earendil-works/pi-durable");
 * const { Type } = require("@earendil-works/pi-ai");
 * module.exports = defineExtension({ name: "weather", tools: [defineTool({ … })] });
 * ```
 */
export function evaluateExtension(source: string, name: string, sourceURL: string | undefined): Extension {
	const module = { exports: {} as Record<string, unknown> };
	const require = (id: string) => {
		if (!(id in modules)) {
			throw new Error(`Cannot find module '${id}'. Extensions can require: ${Object.keys(modules).join(", ")}`);
		}
		return modules[id];
	};
	const url = sourceURL ?? `pi-durable-extension:${name}`;
	const body = new Function("module", "exports", "require", `${source}\n//# sourceURL=${url}`);
	body(module, module.exports, require);
	const exported = (module.exports.default ?? module.exports) as Partial<Extension>;
	if (typeof exported?.name !== "string") {
		throw new Error(`${url} must export a pi-durable extension: module.exports = defineExtension({ name, … })`);
	}
	if (exported.name !== name) {
		throw new Error(`${url} defines extension "${exported.name}", but was installed as "${name}"`);
	}
	return exported as Extension;
}
