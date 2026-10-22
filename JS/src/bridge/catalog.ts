// Newer model catalogs than the bundle's, from pi.dev, as pi has them: each built-in provider's models with a
// persisted overlay of pi.dev's catalog for it, so models released after this bundle was built are there without an
// update. Ported from pi-coding-agent's `remote-catalog-provider.ts` and `model-runtime.ts` (MIT), keeping their
// behavior: a 4 hour freshness window, ETag revalidation, catalogs older than the bundle ignored, and OpenRouter's
// catalog narrowed to what the person's key can use.
import {
	type AnyModel,
	getModelType,
	isModelType,
	type ModelsStore,
	type ModelsStoreEntry,
	type ModelType,
	type Provider,
	type RefreshModelsContext,
} from "@earendil-works/pi-ai";
import { getBuiltinModelDataGeneratedAt } from "@earendil-works/pi-ai/providers/all";
import { personalizeOpenRouterCatalog } from "@earendil-works/pi-ai/providers/openrouter";
import { formatUserAgent } from "@earendil-works/pi-ai";
import { clientIdentity } from "../shims/client.ts";
import { host } from "./core.ts";

const REMOTE_CATALOG_ATTEMPT_TIMEOUT_MS = 4_000;
const REMOTE_CATALOG_REFRESH_INTERVAL_MS = 4 * 60 * 60 * 1000;
/** Model types this client can consume, sent as `?types=` for the catalog with every type. */
const REMOTE_CATALOG_MODEL_TYPES: readonly ModelType[] = ["chat", "image", "classifier"];
const RETRYABLE_STATUS_CODES = new Set([408, 425, 429, 500, 502, 503, 504]);

/** The built-in providers with pi.dev's catalogs over them, as pi's model runtime wraps them. */
export function withRemoteCatalogs(providers: readonly Provider[], catalogBaseUrl: string): Provider[] {
	const generatedAt = getBuiltinModelDataGeneratedAt();
	return providers.map((provider) => {
		if (provider.id === "radius") return provider;
		// OpenRouter narrows the catalog to the models, limits and prices of the person's key.
		if (provider.id === "openrouter") {
			return withPersonalizedCatalog(provider, personalizeOpenRouterCatalog, catalogBaseUrl, generatedAt);
		}
		return withRemoteCatalog(provider, catalogBaseUrl, generatedAt);
	});
}

/** Catalogs kept by Swift (as files, or in memory), so the overlays are there offline and after a relaunch. */
export class HostModelsStore implements ModelsStore {
	readonly #models: number;

	constructor(models: number) {
		this.#models = models;
	}

	async read(providerId: string): Promise<ModelsStoreEntry | undefined> {
		return (await host<ModelsStoreEntry | null>("modelsStore.read", { models: this.#models, provider: providerId })) ?? undefined;
	}

	async write(providerId: string, entry: ModelsStoreEntry): Promise<void> {
		await host("modelsStore.write", { models: this.#models, provider: providerId, entry });
	}

	async delete(providerId: string): Promise<void> {
		await host("modelsStore.write", { models: this.#models, provider: providerId, entry: null });
	}
}

function isSupportedModelType(model: { type?: unknown }): boolean {
	return (
		model.type === undefined ||
		(typeof model.type === "string" && REMOTE_CATALOG_MODEL_TYPES.includes(model.type as ModelType))
	);
}

function mergeModels<TModel extends AnyModel>(baseline: readonly TModel[], dynamic: readonly TModel[]): TModel[] {
	const merged = new Map<string, TModel>();
	for (const model of [...baseline, ...dynamic]) merged.set(`${getModelType(model)}\0${model.id}`, model);
	return [...merged.values()];
}

function parseCatalog(providerId: string, value: unknown): AnyModel[] {
	const entries = Array.isArray(value)
		? value
		: typeof value === "object" && value !== null && "models" in value && Array.isArray(value.models)
			? value.models
			: typeof value === "object" && value !== null
				? Object.values(value)
				: undefined;
	if (!entries) throw new Error(`Invalid model catalog for provider "${providerId}"`);
	return entries
		.filter((entry): entry is Record<string, unknown> => typeof entry === "object" && entry !== null && "id" in entry)
		.filter(isSupportedModelType)
		.map((model) => ({ ...model, provider: providerId }) as AnyModel);
}

/** Reads a successful catalog response. A missing or invalid Last-Modified header is 0. */
async function readCatalog(
	providerId: string,
	response: Response,
): Promise<{ models: AnyModel[]; lastModified: number; etag: string | undefined }> {
	const lastModified = Date.parse(response.headers.get("last-modified") ?? "");
	return {
		models: parseCatalog(providerId, await response.json()),
		lastModified: Number.isNaN(lastModified) ? 0 : lastModified,
		etag: response.headers.get("etag") ?? undefined,
	};
}

/** Whether a catalog is newer than the model data bundled. */
function isNewer(lastModified: number | undefined, localGeneratedAt: number | undefined): boolean {
	return localGeneratedAt === undefined || (lastModified !== undefined && lastModified > localGeneratedAt);
}

function remoteModels(entry: ModelsStoreEntry | undefined, localGeneratedAt: number | undefined): readonly AnyModel[] {
	return entry && isNewer(entry.lastModified, localGeneratedAt) ? entry.models : [];
}

/** A catalog request, retried twice on a transport failure or a transient status, each attempt timed out. */
async function requestCatalog(
	providerId: string,
	catalogBaseUrl: string,
	signal: AbortSignal,
	validator?: string,
): Promise<Response> {
	const url = new URL(`/api/models/providers/${encodeURIComponent(providerId)}`, catalogBaseUrl);
	url.searchParams.set("types", REMOTE_CATALOG_MODEL_TYPES.join(","));
	const headers: Record<string, string> = {
		accept: "application/json",
		"User-Agent": formatUserAgent(clientIdentity()),
		...(validator ? { "if-none-match": validator } : {}),
	};
	for (let attempt = 0; ; attempt++) {
		signal.throwIfAborted();
		const attemptSignal = AbortSignal.any([signal, AbortSignal.timeout(REMOTE_CATALOG_ATTEMPT_TIMEOUT_MS)]);
		try {
			const response = await fetch(url, { headers, signal: attemptSignal });
			if (!RETRYABLE_STATUS_CODES.has(response.status) || attempt >= 2) return response;
			await response.body?.cancel().catch(() => undefined);
		} catch (error) {
			if (signal.aborted || attempt >= 2) throw error;
		}
	}
}

type PersonalizeCatalog = (catalog: readonly AnyModel[], context: RefreshModelsContext) => Promise<readonly AnyModel[]>;

/** Adds a persisted catalog overlay to a static built-in provider. */
function withRemoteCatalog(provider: Provider, catalogBaseUrl: string, localGeneratedAt?: number): Provider {
	let dynamicModels: readonly AnyModel[] = [];

	return {
		...provider,
		getModels: () =>
			mergeModels(
				provider.getModels(),
				dynamicModels.filter((model) => isModelType(model, "chat")),
			),
		getAllModels: () => mergeModels(provider.getAllModels?.() ?? provider.getModels(), dynamicModels),
		refreshModels: async (context) => {
			const stored = context.stored;
			const restored = remoteModels(stored, localGeneratedAt).filter((model) => model.provider === provider.id);
			if (
				!(await context.publish({
					update: () => {
						dynamicModels = restored;
					},
				}))
			) {
				return;
			}
			if (!context.allowNetwork || context.signal.aborted) return;
			// Skip the request if the catalog was checked less than the refresh interval ago. An entry without
			// lastModified (after a failed first request) is always refetched: remoteModels() ignores it.
			if (
				!context.force &&
				stored?.checkedAt !== undefined &&
				stored.lastModified !== undefined &&
				Date.now() - stored.checkedAt < REMOTE_CATALOG_REFRESH_INTERVAL_MS
			) {
				return;
			}

			// Only revalidate when a cached body backs the validator, so a 304 can never leave the overlay empty.
			const validator = stored && stored.models.length > 0 ? stored.etag : undefined;
			const response = await requestCatalog(provider.id, catalogBaseUrl, context.signal, validator);
			if (context.signal.aborted) return;
			const checkedAt = Date.now();
			// Unchanged: dynamicModels already holds the stored overlay, so only the freshness window moves.
			if (response.status === 304 && stored) {
				await context.publish({ persist: { ...stored, checkedAt } });
				return;
			}
			if (response.status === 404 || response.status === 501) {
				await context.publish({
					persist: { ...(stored ?? { models: [] }), checkedAt, lastModified: 0, etag: undefined },
				});
				return;
			}
			if (!response.ok) {
				// Transient failure: the cached body and its validator stay valid, so keep the etag and let the next
				// refresh revalidate instead of downloading the catalog.
				await context.publish({ persist: { ...(stored ?? { models: [] }), checkedAt } });
				throw new Error(`Model catalog request failed for ${provider.id}: ${response.status}`);
			}
			const catalog = await readCatalog(provider.id, response);
			if (context.signal.aborted) return;
			const entry: ModelsStoreEntry = { ...catalog, checkedAt };
			const published = remoteModels(entry, localGeneratedAt);
			await context.publish({
				persist: entry,
				update: () => {
					dynamicModels = published;
				},
			});
		},
	};
}

/**
 * Like `withRemoteCatalog`, but on each network refresh the catalog (built-in models plus a newer one) is passed
 * through `personalize` and the result is saved, replacing the catalog, offline too. An empty list falls back to the
 * built-in models.
 */
function withPersonalizedCatalog(
	provider: Provider,
	personalize: PersonalizeCatalog,
	catalogBaseUrl: string,
	localGeneratedAt?: number,
): Provider {
	let personalModels: readonly AnyModel[] = [];
	const builtinModels = (): readonly AnyModel[] => provider.getAllModels?.() ?? provider.getModels();
	const getAllModels = (): readonly AnyModel[] => (personalModels.length > 0 ? personalModels : builtinModels());

	return {
		...provider,
		getModels: () => getAllModels().filter((model) => isModelType(model, "chat")),
		getAllModels,
		refreshModels: async (context) => {
			const restored = (context.stored?.models ?? []).filter((model) => model.provider === provider.id);
			if (
				!(await context.publish({
					update: () => {
						personalModels = restored;
					},
				}))
			) {
				return;
			}
			if (!context.allowNetwork || context.signal.aborted) return;

			const response = await requestCatalog(provider.id, catalogBaseUrl, context.signal);
			if (context.signal.aborted) return;
			let remote: readonly AnyModel[] = [];
			if (response.status !== 404 && response.status !== 501) {
				if (!response.ok) throw new Error(`Model catalog request failed for ${provider.id}: ${response.status}`);
				const catalog = await readCatalog(provider.id, response);
				if (isNewer(catalog.lastModified, localGeneratedAt)) remote = catalog.models;
			}
			const personalized = await personalize(mergeModels(builtinModels(), remote), context);
			if (context.signal.aborted) return;
			await context.publish({
				persist: { models: personalized, checkedAt: Date.now() },
				update: () => {
					personalModels = personalized;
				},
			});
		},
	};
}

/**
 * A custom provider serving a built-in provider's models (`CustomProvider.catalog`): the source's catalog (its built-in
 * models and pi.dev's newer ones), each pointed at the custom provider (its ID, address and headers). Refreshing it
 * refreshes the source's catalog overlay, under the custom provider's own credential, so it stays current whether or
 * not the source itself is signed in.
 */
export function followingCatalog(custom: Provider, source: Provider, retarget: (model: AnyModel) => AnyModel): Provider {
	return {
		...custom,
		getModels: () => source.getModels().map((model) => retarget(model)) as ReturnType<Provider["getModels"]>,
		getAllModels: () => (source.getAllModels?.() ?? source.getModels()).map(retarget),
		...(source.refreshModels ? { refreshModels: (context: RefreshModelsContext) => source.refreshModels!(context) } : {}),
	};
}

