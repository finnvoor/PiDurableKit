// Model access: pi-ai Models collections, credentials kept by Swift, OAuth sign-in, custom and faux providers.
import type { Context } from "@earendil-works/chord";
import {
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
	type Model,
	type MutableModels,
	type ProviderStreams,
} from "@earendil-works/pi-ai";
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
		reasoning: model.reasoning,
		input: model.input,
		contextWindow: model.contextWindow,
		maxTokens: model.maxTokens,
		cost: model.cost,
	};
}

/** pi-ai's chat API implementations a custom provider can use, by `model.api`. */
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
	"models.complete": (args, context: ChordContext) => {
		const request = requestOf(args, context.abortSignal);
		return request.models.completeSimple(request.model, request.context as never, request.options as never);
	},
	"models.stream": (args) => {
		const controller = new AbortController();
		const request = requestOf(args, controller.signal);
		const stream = args.stream as number;
		openStream(stream, () => controller.abort());
		void (async () => {
			try {
				for await (const event of request.models.streamSimple(request.model, request.context as never, request.options as never)) {
					// `partial` repeats the whole message on every event; Swift rebuilds it from the deltas.
					const { partial: _partial, ...rest } = event as Args;
					emit(stream, rest);
				}
				finish(stream);
			} catch (error) {
				finish(stream, error);
			}
		})();
	},

	"models.create": (args) => {
		const credentials = new HostCredentialStore(args.id);
		const models = createModels({ credentials });
		if (args.builtin !== false) for (const provider of builtinProviders()) models.setProvider(provider);
		modelSets.set(args.id, { models, credentials, fauxes: new Map() });
	},
	"models.dispose": (args) => {
		modelSets.delete(args.id);
	},
	"models.setAPIKey": async (args) => {
		const { credentials } = modelsState(args.id);
		if (args.key === null) await credentials.delete(args.provider);
		else await credentials.modify(args.provider, async () => ({ type: "api_key", key: args.key }) as never);
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
		}, { getDeviceId: () => args.deviceId as string });
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
		const api: Record<string, ProviderStreams> = {};
		for (const model of models) {
			const implementation = apis[model.api];
			if (implementation === undefined) throw new Error(`Unsupported API "${model.api}"`);
			api[model.api] ??= implementation();
		}
		// Keyless servers (Ollama, LM Studio) still get a placeholder key: the SDKs refuse to send without one.
		const keyless = spec.apiKey === undefined || spec.apiKey === null;
		state.models.setProvider(
			createProvider({
				id: spec.id,
				name: spec.name ?? spec.id,
				baseUrl: spec.baseUrl,
				...(spec.headers ? { headers: spec.headers } : {}),
				auth: {
					apiKey: keyless
						? { name: spec.name ?? spec.id, resolve: async () => ({ auth: { apiKey: "unused" } }) }
						: envApiKeyAuth(spec.name ?? spec.id, []),
				},
				models: models as never,
				api: api as never,
			}) as never,
		);
		if (!keyless) await state.credentials.modify(spec.id, async () => ({ type: "api_key", key: spec.apiKey }) as never);
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
