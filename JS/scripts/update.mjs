#!/usr/bin/env node
// Updates the bundled pi-durable (and the pi-ai and chord it runs on), then rebuilds the bundle.
//
//   npm run update               # latest pi-durable
//   npm run update -- 1.0.5      # a specific version
//
// Prints `changed=true|false` and `version=<x.y.z>` lines (also written to $GITHUB_OUTPUT in CI).
import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const run = (command, args, options = {}) =>
	execFileSync(command, args, { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"], ...options })?.trim() ?? "";
const npmView = (spec, field) => JSON.parse(run("npm", ["view", spec, field, "--json"]) || "null");

const requested = process.argv[2] ?? "latest";
const durable = npmView(`@earendil-works/pi-durable@${requested}`, "version");
const version = Array.isArray(durable) ? durable.at(-1) : durable;
if (typeof version !== "string") throw new Error(`No pi-durable release matches "${requested}"`);

const installed = JSON.parse(readFileSync(resolve(root, "package.json"), "utf8")).dependencies;
const previous = installed["@earendil-works/pi-durable"];

/** The newest release of a dependency that satisfies pi-durable's declared range. */
function dependencyVersion(name) {
	const range = npmView(`@earendil-works/pi-durable@${version}`, "dependencies")[name];
	if (range === undefined) throw new Error(`pi-durable ${version} no longer depends on ${name}`);
	// Prefer the lockstep release when it satisfies the range; otherwise the newest match.
	const candidates = [].concat(npmView(`${name}@${range}`, "version") ?? []);
	if (candidates.includes(version)) return version;
	if (candidates.length === 0) throw new Error(`No ${name} release satisfies ${range}`);
	return candidates.at(-1);
}

const piAI = dependencyVersion("@earendil-works/pi-ai");
const chord = dependencyVersion("@earendil-works/chord");
console.error(`Updating pi-durable ${previous} → ${version} (pi-ai ${piAI}, chord ${chord})`);

run("npm", [
	"install",
	"--save-exact",
	`@earendil-works/pi-durable@${version}`,
	`@earendil-works/pi-ai@${piAI}`,
	`@earendil-works/chord@${chord}`,
], { stdio: ["ignore", "inherit", "inherit"] });
run("npm", ["run", "build"], { stdio: ["ignore", "inherit", "inherit"] });

const changed = previous !== version || installed["@earendil-works/pi-ai"] !== piAI || installed["@earendil-works/chord"] !== chord;
const output = `changed=${changed}\nversion=${version}\nprevious=${previous}\n`;
process.stdout.write(output);
if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, output);
