// How the app identifies itself to model providers, wherever pi-ai would say "pi" (`Runtime.Client` in Swift).
//
// The app's `ClientIdentity` goes to every `Models` and harness (its `User-Agent` and attribution), and build.mjs
// patches pi-ai's other "pi"s (the sign-in name, OpenAI Codex's originator, xAI's referrer) to `clientName()`.
// Strict explicitly: esbuild reaches this module from several importers (patched pi-ai modules among them), and whether
// it marked it strict depended on which got there first, so the committed bundle didn't match CI's.
"use strict";

import type { ClientIdentity } from "@earendil-works/pi-ai";
import { native } from "../runtime/native.ts";

interface Client {
	name: string;
	/** pi-ai's `ClientIdentity` of the runtime's requests: the app's `User-Agent` and attribution. */
	identity: ClientIdentity;
}

let client: Client | undefined;

function current(): Client {
	// Outside the Swift host (the Node tests), a name of its own.
	client ??=
		typeof native?.client === "function"
			? (JSON.parse(native.client()) as Client)
			: { name: "PiDurableKit", identity: { userAgent: { custom: "PiDurableKit" }, attribution: null } };
	return client;
}

/** The app's name, such as "Pelican". */
export function clientName(): string {
	return current().name;
}

/** The runtime's identity, given to every `Models` and harness (`Runtime.Client.identity`). */
export function clientIdentity(): ClientIdentity {
	return current().identity;
}
