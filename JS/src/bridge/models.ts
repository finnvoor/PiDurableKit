// Model access: pi-ai Models collections, credentials kept by Swift, OAuth sign-in, custom and faux providers.
import type { Context } from "@earendil-works/chord";
import {
	type AnyModel,
	type AssistantMessage,
	type AuthEvent,
	type AuthPrompt,
	type Credential,
	type CredentialInfo,
	type CredentialStore,
	createModels,
	createProvider,
	envApiKeyAuth,
	fauxAssistantMessage,
	type FauxProviderHandle,
	fauxProvider,
	getSupportedThinkingLevels,
	type Model,
	type MutableModels,
	type OAuthAuth,
	type OAuthCredential,
	type Provider,
	type ProviderAuthInteraction,
	type ProviderStreams,
} from "@earendil-works/pi-ai";
// pi-ai's own sign-in pieces, which its package doesn't export: the loopback redirect server (Network.framework, through
// the node:http shim), PKCE, and the device-code poller.
import { clientIdentity } from "../shims/client.ts";
import { inSpan } from "./telemetry.ts";
import { startOAuthCallbackServer } from "../../node_modules/@earendil-works/pi-ai/dist/auth/oauth/callback-server.js";
import { pollOAuthDeviceCodeFlow } from "../../node_modules/@earendil-works/pi-ai/dist/auth/oauth/device-code.js";
import { generatePKCE } from "../../node_modules/@earendil-works/pi-ai/dist/auth/oauth/pkce.js";
import { anthropicMessagesApi } from "@earendil-works/pi-ai/api/anthropic-messages.lazy";
import { azureOpenAIResponsesApi } from "@earendil-works/pi-ai/api/azure-openai-responses.lazy";
import { googleGenerativeAIApi } from "@earendil-works/pi-ai/api/google-generative-ai.lazy";
import { googleVertexApi } from "@earendil-works/pi-ai/api/google-vertex.lazy";
import { mistralConversationsApi } from "@earendil-works/pi-ai/api/mistral-conversations.lazy";
import { openAICodexResponsesApi } from "@earendil-works/pi-ai/api/openai-codex-responses.lazy";
import { openAICompletionsApi } from "@earendil-works/pi-ai/api/openai-completions.lazy";
import { openAIResponsesApi } from "@earendil-works/pi-ai/api/openai-responses.lazy";
import { piMessagesApi } from "@earendil-works/pi-ai/api/pi-messages.lazy";
import { registerBunOAuthFlows } from "@earendil-works/pi-ai/bun-oauth";
import { builtinProviders } from "@earendil-works/pi-ai/providers/all";
import { followingCatalog, HostModelsStore, withRemoteCatalogs } from "./catalog.ts";
import { type Args, emit, finish, host, openStream, register } from "./core.ts";
import type { Context as ChordContext } from "@earendil-works/chord";

// MARK: Models

type ModelsState = {
	models: MutableModels;
	credentials: HostCredentialStore;
	fauxes: Map<string, FauxProviderHandle>;
};

// pi-ai's OAuth flows load through a bundler-opaque `import()` by default; embed them statically instead.
// Their Node built-ins (`node:http` for the loopback redirect, `node:crypto`) are host-backed shims.
registerBunOAuthFlows();

/**
 * Credentials kept by the Swift `CredentialStore` (Keychain, memory, or the app's own). Read-modify-write is
 * serialized per provider, so concurrent requests never refresh one OAuth token twice.
 */
class HostCredentialStore implements CredentialStore {
	readonly #models: number;
	readonly #chains = new Map<string, Promise<unknown>>();

	constructor(models: number) {
		this.#models = models;
	}

	async read(providerId: string): Promise<Credential | undefined> {
		return (await host<Credential | null>("credentials.read", { models: this.#models, provider: providerId })) ?? undefined;
	}

	async list(): Promise<readonly CredentialInfo[]> {
		return host<CredentialInfo[]>("credentials.list", { models: this.#models });
	}

	modify(
		providerId: string,
		fn: (current: Credential | undefined) => Promise<Credential | undefined>,
	): Promise<Credential | undefined> {
		return this.#serialized(providerId, async () => {
			const current = await this.read(providerId);
			const next = await fn(current);
			if (JSON.stringify(next) !== JSON.stringify(current)) await this.#write(providerId, next);
			return next;
		});
	}

	delete(providerId: string): Promise<void> {
		return this.#serialized(providerId, () => this.#write(providerId, undefined));
	}

	#write(providerId: string, credential: Credential | undefined): Promise<void> {
		return host("credentials.write", { models: this.#models, provider: providerId, credential: credential ?? null });
	}

	#serialized<T>(providerId: string, operation: () => Promise<T>): Promise<T> {
		const previous = this.#chains.get(providerId) ?? Promise.resolve();
		const result = previous.then(operation, operation);
		const tail = result.then(
			() => undefined,
			() => undefined,
		);
		this.#chains.set(providerId, tail);
		void tail.then(() => {
			if (this.#chains.get(providerId) === tail) this.#chains.delete(providerId);
		});
		return result;
	}
}

export const modelSets = new Map<number, ModelsState>();

export function modelsState(id: number): ModelsState {
	const state = modelSets.get(id);
	if (state === undefined) throw new Error(`Unknown models collection ${id}`);
	return state;
}

function describeModel(model: Model<string>) {
	return {
		provider: model.provider,
		id: model.id,
		name: model.name,
		api: model.api,
		baseUrl: model.baseUrl,
		reasoning: model.reasoning,
		input: model.input,
		contextWindow: model.contextWindow,
		maxTokens: model.maxTokens,
		cost: model.cost,
		// pi-ai's own answer, from the model's reasoning flag and thinking level map.
		thinkingLevels: getSupportedThinkingLevels(model),
	};
}

/** pi-ai's chat API implementations a custom provider can use, by `model.api`. */
/**
 * A custom provider's OAuth (`CustomProvider.OAuth`): how it signs in, if it does (a browser sign-in with PKCE and a
 * loopback redirect, or a device code), and the token endpoint that exchanges and refreshes its tokens.
 */
interface CustomOAuth {
	tokenUrl: string;
	clientId: string | null;
	scope: string | null;
	/** How token requests are sent: `form` (`application/x-www-form-urlencoded`, as OAuth 2 has it) or `json`. */
	format: "form" | "json";
	/** Added to the authorization URL (browser) or the device authorization request (device code). */
	parameters: Record<string, string>;
	signIn:
		| { type: "browser"; authorizationUrl: string; redirectUri: string }
		| { type: "deviceCode"; deviceAuthorizationUrl: string }
		| null;
}

/** An OAuth endpoint's JSON response, or its error. */
async function postOAuth(
	url: string,
	fields: Record<string, string>,
	format: "form" | "json",
	signal: AbortSignal,
): Promise<{ ok: boolean; status: number; body: Record<string, unknown>; text: string }> {
	const json = format === "json";
	const response = await fetch(url, {
		method: "POST",
		headers: { "content-type": json ? "application/json" : "application/x-www-form-urlencoded", accept: "application/json" },
		body: json ? JSON.stringify(fields) : new URLSearchParams(fields).toString(),
		signal,
	});
	const text = await response.text();
	let body: Record<string, unknown> = {};
	try {
		const parsed = JSON.parse(text) as unknown;
		if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) body = parsed as Record<string, unknown>;
	} catch {
		// Not JSON: the text says what went wrong.
	}
	return { ok: response.ok, status: response.status, body, text };
}

function oauthFailure(action: string, response: { status: number; body: Record<string, unknown>; text: string }): Error {
	const error = typeof response.body.error === "string" ? response.body.error : undefined;
	const description = typeof response.body.error_description === "string" ? response.body.error_description : undefined;
	const detail = [error, description].filter(Boolean).join(": ") || response.text.slice(0, 300);
	return new Error(`${action} failed (HTTP ${response.status})${detail ? `: ${detail}` : ""}`);
}

/** Tokens from a token endpoint's response; servers that don't rotate refresh tokens leave theirs out. */
function oauthCredential(body: Record<string, unknown>, previous?: OAuthCredential): OAuthCredential {
	if (typeof body.access_token !== "string" || body.access_token === "") throw new Error("The token endpoint returned no access_token");
	const expiresIn = typeof body.expires_in === "number" && body.expires_in > 0 ? body.expires_in : 3600;
	return {
		...(previous ?? {}),
		type: "oauth",
		access: body.access_token,
		refresh: typeof body.refresh_token === "string" ? body.refresh_token : (previous?.refresh ?? ""),
		// A minute early, so a request never goes out with a token about to lapse.
		expires: Date.now() + Math.max(expiresIn - 60, 0) * 1000,
	};
}

/** A browser sign-in: the authorization page with PKCE, its redirect caught on a loopback port, the code exchanged. */
async function browserSignIn(
	name: string,
	oauth: CustomOAuth,
	signIn: { authorizationUrl: string; redirectUri: string },
	interaction: ProviderAuthInteraction,
): Promise<OAuthCredential> {
	const redirect = new URL(signIn.redirectUri);
	if (redirect.protocol !== "http:" || !["localhost", "127.0.0.1", "[::1]"].includes(redirect.hostname) || !redirect.port) {
		throw new Error("The redirect URI must be a loopback address with a port, like http://localhost:1455/callback");
	}
	const { verifier, challenge } = await generatePKCE();
	const state = Array.from(crypto.getRandomValues(new Uint8Array(16)), (byte) => byte.toString(16).padStart(2, "0")).join("");
	const callback = await startOAuthCallbackServer({
		providerName: name,
		host: "127.0.0.1",
		port: Number(redirect.port),
		path: redirect.pathname,
		redirectHost: redirect.hostname,
		state,
		complete: async (code: string) => code,
		signal: interaction.signal,
	});
	try {
		const url = new URL(signIn.authorizationUrl);
		const query: Record<string, string> = {
			response_type: "code",
			redirect_uri: signIn.redirectUri,
			code_challenge: challenge,
			code_challenge_method: "S256",
			state,
			...(oauth.clientId ? { client_id: oauth.clientId } : {}),
			...(oauth.scope ? { scope: oauth.scope } : {}),
			...oauth.parameters,
		};
		for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value);
		interaction.notify({ type: "auth_url", url: url.toString() });
		const code = await callback.wait();
		if (!code) throw new Error("Sign-in cancelled");
		interaction.notify({ type: "progress", message: "Exchanging authorization code for tokens..." });
		const response = await postOAuth(
			oauth.tokenUrl,
			{
				grant_type: "authorization_code",
				code,
				redirect_uri: signIn.redirectUri,
				code_verifier: verifier,
				// Some servers (Anthropic's) want the state back; others ignore it.
				state,
				...(oauth.clientId ? { client_id: oauth.clientId } : {}),
			},
			oauth.format,
			interaction.signal,
		);
		if (!response.ok) throw oauthFailure("Token exchange", response);
		return oauthCredential(response.body);
	} finally {
		callback.close();
	}
}

/** A device-code sign-in (RFC 8628): a code to enter on the provider's page, then the token endpoint polled. */
async function deviceCodeSignIn(
	oauth: CustomOAuth,
	signIn: { deviceAuthorizationUrl: string },
	interaction: ProviderAuthInteraction,
): Promise<OAuthCredential> {
	const request: Record<string, string> = {
		...(oauth.clientId ? { client_id: oauth.clientId } : {}),
		...(oauth.scope ? { scope: oauth.scope } : {}),
		...oauth.parameters,
	};
	const authorization = await postOAuth(signIn.deviceAuthorizationUrl, request, oauth.format, interaction.signal);
	if (!authorization.ok) throw oauthFailure("Device authorization", authorization);
	const body = authorization.body;
	const deviceCode = body.device_code;
	const userCode = body.user_code;
	const page = body.verification_uri_complete ?? body.verification_uri ?? body.verification_url;
	if (typeof deviceCode !== "string" || typeof userCode !== "string" || typeof page !== "string") {
		throw new Error("The device authorization response is missing device_code, user_code or verification_uri");
	}
	if (new URL(page).protocol !== "https:") throw new Error("The device authorization response's page isn't https");
	const intervalSeconds = typeof body.interval === "number" && body.interval > 0 ? body.interval : undefined;
	const expiresInSeconds = typeof body.expires_in === "number" && body.expires_in > 0 ? body.expires_in : undefined;
	interaction.notify({ type: "device_code", userCode, verificationUri: page, intervalSeconds, expiresInSeconds });
	return pollOAuthDeviceCodeFlow<OAuthCredential>({
		intervalSeconds,
		expiresInSeconds,
		waitBeforeFirstPoll: true,
		signal: interaction.signal,
		poll: async () => {
			const response = await postOAuth(
				oauth.tokenUrl,
				{
					grant_type: "urn:ietf:params:oauth:grant-type:device_code",
					device_code: deviceCode,
					...(oauth.clientId ? { client_id: oauth.clientId } : {}),
				},
				oauth.format,
				interaction.signal,
			);
			if (response.ok) return { status: "complete", value: oauthCredential(response.body) };
			const error = response.body.error;
			if (error === "authorization_pending") return { status: "pending" };
			if (error === "slow_down") {
				const interval = response.body.interval;
				return { status: "slow_down", intervalSeconds: typeof interval === "number" ? interval : undefined };
			}
			return { status: "failed", message: oauthFailure("Sign-in", response).message };
		},
	});
}

/**
 * OAuth auth for a custom provider: signing in in the browser or with a device code, or with tokens stored with
 * `Models.setCredential` when it has no sign-in. pi-ai's `Models` refreshes the tokens through `tokenUrl` before they
 * expire, and requests send the access token as the API key.
 */
function customOAuthAuth(name: string, oauth: CustomOAuth): OAuthAuth {
	return {
		name,
		loginLabel: `Sign in to ${name}`,
		login: async (interaction) => {
			const signIn = oauth.signIn;
			if (signIn === null) throw new Error(`${name} has no sign-in; store its tokens instead`);
			return signIn.type === "browser"
				? browserSignIn(name, oauth, signIn, interaction)
				: deviceCodeSignIn(oauth, signIn, interaction);
		},
		refresh: async (credential, signal) => {
			if (!credential.refresh) throw new Error(`${name}'s sign-in has no refresh token; sign in again`);
			const response = await postOAuth(
				oauth.tokenUrl,
				// No scope: it's optional on a refresh (the sign-in's carries over), and some servers (Anthropic's)
				// reject one.
				{
					grant_type: "refresh_token",
					refresh_token: credential.refresh,
					...(oauth.clientId ? { client_id: oauth.clientId } : {}),
				},
				oauth.format,
				signal,
			);
			if (!response.ok) throw oauthFailure("Token refresh", response);
			return oauthCredential(response.body, credential);
		},
		toAuth: async (credential) => ({ apiKey: credential.access }),
	};
}

const apis: Record<string, () => ProviderStreams> = {
	"anthropic-messages": anthropicMessagesApi,
	"azure-openai-responses": azureOpenAIResponsesApi,
	"google-generative-ai": googleGenerativeAIApi,
	"google-vertex": googleVertexApi,
	"mistral-conversations": mistralConversationsApi,
	"openai-codex-responses": openAICodexResponsesApi,
	"openai-completions": openAICompletionsApi,
	"openai-responses": openAIResponsesApi,
	"pi-messages": piMessagesApi,
};

function fauxStep(step: Args) {
	return fauxMessage(step);
}

/** A response step that asks Swift for the response, and queues itself again for the next request. */
function fauxResponder(models: number, provider: string, faux: FauxProviderHandle) {
	const step = async (context: { messages: unknown[] }, _options: unknown, state: { callCount: number }) => {
		faux.appendResponses([step as never]);
		return fauxMessage(await host<Args>("faux.respond", { models, provider, messages: context.messages, callCount: state.callCount }));
	};
	return step;
}

function fauxMessage(step: Args): AssistantMessage {
	return fauxAssistantMessage(step.content ?? [], {
		stopReason: step.stopReason,
		errorMessage: step.errorMessage,
	});
}

function requestOf(args: Args, signal: AbortSignal | undefined) {
	const { models } = modelsState(args.id);
	const model = models.getModel(args.model.provider, args.model.modelId);
	if (model === undefined) {
		throw Object.assign(new Error(`Unknown model ${args.model.provider}/${args.model.modelId}`), { name: "NotFound" });
	}
	const context = {
		...(args.context.systemPrompt == null ? {} : { systemPrompt: args.context.systemPrompt }),
		messages: args.context.messages,
		...(args.context.tools == null ? {} : { tools: args.context.tools }),
	};
	return { models, model, context, options: { ...(args.options ?? {}), signal } };
}

register({
	// pi-ai `models.completeSimple` / `models.streamSimple`, for tools and tasks that call a model themselves.
	// With `telemetry`, the request records in a new root span of that recorder (pi-ai `options.telemetry`).
	"models.complete": (args, context: ChordContext) => {
		const request = requestOf(args, context.abortSignal);
		return inSpan(args.telemetry, (span) =>
			request.models.completeSimple(request.model, request.context as never, { ...request.options, ...(span ? { telemetry: span } : {}) } as never),
		);
	},
	"models.stream": (args) => {
		const controller = new AbortController();
		const request = requestOf(args, controller.signal);
		const stream = args.stream as number;
		openStream(stream, () => controller.abort());
		void (async () => {
			try {
				await inSpan(args.telemetry, async (span) => {
					const options = { ...request.options, ...(span ? { telemetry: span } : {}) };
					for await (const event of request.models.streamSimple(request.model, request.context as never, options as never)) {
						// `partial` repeats the whole message on every event; Swift rebuilds it from the deltas.
						const { partial: _partial, ...rest } = event as Args;
						emit(stream, rest);
					}
				});
				finish(stream);
			} catch (error) {
				finish(stream, error);
			}
		})();
	},

	// With a `catalog` URL, the built-in providers get its newer catalogs, as pi does; those kept from before are
	// restored straight away (offline), and `models.refresh` checks for newer ones.
	"models.create": async (args) => {
		const credentials = new HostCredentialStore(args.id);
		const catalog = (args.catalog as string | null | undefined) ?? undefined;
		// Every request identifies the app (`Runtime.Client`), unless a harness or the request itself says otherwise.
		const models = createModels({
			credentials,
			identity: clientIdentity(),
			...(catalog ? { modelsStore: new HostModelsStore(args.id) } : {}),
		});
		if (args.builtin !== false) {
			const providers = builtinProviders();
			for (const provider of catalog ? withRemoteCatalogs(providers, catalog) : providers) models.setProvider(provider);
		}
		modelSets.set(args.id, { models, credentials, fauxes: new Map() });
		if (catalog && args.builtin !== false) await models.refresh({ allowNetwork: false });
	},
	"models.dispose": (args) => {
		modelSets.delete(args.id);
	},
	"models.setAPIKey": async (args) => {
		const { credentials } = modelsState(args.id);
		if (args.key === null) await credentials.delete(args.provider);
		else await credentials.modify(args.provider, async () => ({ type: "api_key", key: args.key }) as never);
	},
	"models.setCredential": async (args) => {
		const { credentials } = modelsState(args.id);
		if (args.credential === null) await credentials.delete(args.provider);
		else await credentials.modify(args.provider, async () => args.credential as never);
	},
	"models.list": (args) => {
		const { models } = modelsState(args.id);
		return models.getModels(args.provider ?? undefined).map(describeModel);
	},
	"models.providers": (args) =>
		modelsState(args.id)
			.models.getProviders()
			.map((provider) => ({
				id: provider.id,
				name: provider.name ?? provider.id,
				acceptsAPIKey: provider.auth.apiKey !== undefined,
				oauth:
					provider.auth.oauth === undefined
						? null
						: {
								name: provider.auth.oauth.name,
								label: provider.auth.oauth.loginLabel ?? null,
								isSubscription: provider.auth.oauth.isSubscription === true,
							},
			})),
	"models.login": async (args, context) => {
		const { models } = modelsState(args.id);
		const login = args.login as number;
		const overall = context.abortSignal!;
		const credential = await models.login(args.provider, "oauth", {
			signal: overall,
			prompt: (prompt: AuthPrompt) => {
				const { signal, ...rest } = prompt;
				const abortSignal = signal === undefined ? overall : AbortSignal.any([signal, overall]);
				return host<string>("login.prompt", { login, prompt: rest }, { abortSignal } as Context);
			},
			notify: (event: AuthEvent) => {
				void host("login.notify", { login, event }).catch(() => undefined);
			},
		}, { getDeviceId: () => args.deviceId as string, agentName: (args.agentName as string | null) ?? undefined });
		return { type: credential.type };
	},
	"models.logout": (args) => modelsState(args.id).models.logout(args.provider),
	"models.isConfigured": async (args) => {
		const auth = await modelsState(args.id).models.getAuth(args.provider);
		return auth !== undefined;
	},
	// pi-ai `createProvider`: `args.provider` carries its options, and `models` are pi-ai `Model` objects whose omitted
	// fields default like models.json custom providers (provider, baseUrl, and headers inherited from the provider).
	"models.addProvider": async (args) => {
		const state = modelsState(args.id);
		const spec = args.provider as Args;
		const models = (spec.models as Args[]).map((model) => ({
			name: model.id,
			reasoning: false,
			input: ["text"],
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
			contextWindow: 128000,
			maxTokens: 16384,
			...model,
			api: model.api ?? spec.api,
			provider: spec.id,
			baseUrl: model.baseUrl ?? spec.baseUrl,
			...(spec.headers || model.headers ? { headers: { ...(spec.headers ?? {}), ...(model.headers ?? {}) } } : {}),
		}));
		// Serving a built-in provider's models: its catalog, pointed here, and kept current.
		const source = typeof spec.catalog === "string" ? state.models.getProviders().find((candidate) => candidate.id === spec.catalog) : undefined;
		const api: Record<string, ProviderStreams> = {};
		const sourceModels = source ? (source.getModels() as unknown as { api: string }[]) : [];
		for (const model of [...models, ...sourceModels]) {
			const implementation = apis[model.api];
			if (implementation === undefined) throw new Error(`Unsupported API "${model.api}"`);
			api[model.api] ??= implementation();
		}
		// Keyless servers (Ollama, LM Studio) still get a placeholder key: the SDKs refuse to send without one.
		const keyless = spec.apiKey === undefined || spec.apiKey === null;
		let provider = (
				createProvider({
					id: spec.id,
					name: spec.name ?? spec.id,
					baseUrl: spec.baseUrl,
					...(spec.headers ? { headers: spec.headers } : {}),
					auth: {
						apiKey: keyless
							? { name: spec.name ?? spec.id, resolve: async () => ({ auth: { apiKey: "unused" } }) }
							: envApiKeyAuth(spec.name ?? spec.id, []),
						...(spec.oauth ? { oauth: customOAuthAuth(spec.name ?? spec.id, spec.oauth as CustomOAuth) } : {}),
					},
					models: models as never,
					api: api as never,
				}) as never
		) as unknown as Provider;
		if (source) {
			const headers = spec.headers as Record<string, string> | undefined;
			provider = followingCatalog(provider, source as unknown as Provider, (model) =>
				({
					...model,
					provider: spec.id,
					baseUrl: spec.baseUrl,
					...(headers || (model as { headers?: Record<string, string> }).headers
						? { headers: { ...((model as { headers?: Record<string, string> }).headers ?? {}), ...(headers ?? {}) } }
						: {}),
				}) as AnyModel,
			);
		}
		state.models.setProvider(provider as never);
		if (!keyless) await state.credentials.modify(spec.id, async () => ({ type: "api_key", key: spec.apiKey }) as never);
	},
	// pi-ai `deleteProvider`: a custom, faux, or Foundation Models provider, or a built-in one. Its stored credential stays.
	"models.removeProvider": (args) => {
		const state = modelsState(args.id);
		state.models.deleteProvider(args.provider);
		state.fauxes.delete(args.provider);
	},
	"models.addFaux": (args) => {
		const state = modelsState(args.id);
		const faux = fauxProvider({
			provider: args.provider,
			models: args.models,
			tokensPerSecond: args.tokensPerSecond ?? undefined,
		});
		state.models.setProvider(faux.provider);
		state.fauxes.set(args.provider, faux);
	},
	"faux.append": (args) => {
		const faux = modelsState(args.id).fauxes.get(args.provider);
		if (faux === undefined) throw new Error(`Unknown faux provider ${args.provider}`);
		faux.appendResponses((args.responses as Args[]).map(fauxStep));
	},
	"faux.set": (args) => {
		const faux = modelsState(args.id).fauxes.get(args.provider);
		if (faux === undefined) throw new Error(`Unknown faux provider ${args.provider}`);
		faux.setResponses((args.responses as Args[]).map(fauxStep));
	},
	"faux.respond": (args) => {
		const faux = modelsState(args.id).fauxes.get(args.provider);
		if (faux === undefined) throw new Error(`Unknown faux provider ${args.provider}`);
		faux.setResponses([fauxResponder(args.id, args.provider, faux) as never]);
	},
	"faux.pending": (args) => modelsState(args.id).fauxes.get(args.provider)?.getPendingResponseCount() ?? 0,
	"models.refresh": async (args, context) => {
		const result = await modelsState(args.id).models.refresh({
			providers: args.providers ?? undefined,
			allowNetwork: args.allowNetwork ?? undefined,
			force: args.force ?? undefined,
			signal: context.abortSignal,
		});
		return {
			aborted: result.aborted === true,
			errors: Object.fromEntries([...result.errors].map(([provider, error]) => [provider, error instanceof Error ? error.message : String(error)])),
		};
	},
});
