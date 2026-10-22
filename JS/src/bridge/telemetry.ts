// Telemetry recorders as Swift sees them (`Telemetry` in Swift): pi-telemetry's in-memory recorder, or chord's SQLite
// recorder over a database file or a Swift database. A harness records its content-free spans, events, and metrics in
// one (`HarnessOptions.telemetry`), and Swift reads them back.
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createSqliteTelemetry, type SqliteTelemetry } from "@earendil-works/chord/telemetry-sqlite";
import { AI_TELEMETRY_SCHEMA } from "@earendil-works/pi-ai";
import { DURABLE_TELEMETRY_SCHEMA } from "@earendil-works/pi-durable";
import {
	InMemoryTelemetryContext,
	type MetricQuery,
	type TelemetryContext,
	type TelemetrySpan,
	type TelemetryStore,
	type TraceQuery,
} from "@earendil-works/pi-telemetry";
import { type Args, register } from "./core.ts";
import { HostSqliteDatabase } from "./sqlite.ts";

type Recorder = TelemetryContext & TelemetryStore & Partial<Pick<SqliteTelemetry, "flush" | "close" | "droppedSpans" | "droppedMeasurements">>;

const recorders = new Map<number, Recorder>();

/** A recorder Swift created, by its ID. */
export function telemetryOf(id: number): TelemetryContext {
	const recorder = recorders.get(id);
	if (recorder === undefined) throw new Error("The telemetry recorder is closed");
	return recorder;
}

/** Runs `body` in a new root span of the recorder `spec` names (`{ telemetry, span }`), or without telemetry. */
export function inSpan<T>(spec: Args | null | undefined, body: (span: TelemetrySpan | undefined) => Promise<T>): Promise<T> {
	if (spec == null) return body(undefined);
	return telemetryOf(spec.telemetry).startSpan({ name: spec.span ?? "request" }, (span) => body(span));
}

function recorderOf(args: Args): Recorder {
	const recorder = recorders.get(args.telemetry);
	if (recorder === undefined) throw new Error("The telemetry recorder is closed");
	return recorder;
}

register({
	"telemetry.create": async (args) => {
		let recorder: Recorder;
		const options = {
			...(args.retentionMs == null ? {} : { retentionMs: args.retentionMs }),
			...(args.maxQueuedSpans == null ? {} : { maxQueuedSpans: args.maxQueuedSpans }),
		};
		switch (args.kind) {
			case "sqlite":
				recorder = await createSqliteTelemetry(await openNodeSqliteDatabase(args.path), options);
				break;
			case "database":
				recorder = await createSqliteTelemetry(new HostSqliteDatabase(args.database), options);
				break;
			default:
				recorder = new InMemoryTelemetryContext();
		}
		recorders.set(args.telemetry, recorder);
	},
	"telemetry.traces": (args) => {
		const query = (args.query ?? {}) as TraceQuery;
		return recorderOf(args).findTraces(query);
	},
	"telemetry.trace": async (args) => (await recorderOf(args).getTrace(args.trace)) ?? null,
	"telemetry.metrics": (args) => recorderOf(args).findMetrics(args.query as MetricQuery),
	"telemetry.flush": async (args) => {
		await recorderOf(args).flush?.();
	},
	"telemetry.dropped": (args) => {
		const recorder = recorderOf(args);
		return { spans: recorder.droppedSpans ?? 0, measurements: recorder.droppedMeasurements ?? 0 };
	},
	"telemetry.close": async (args) => {
		const recorder = recorders.get(args.telemetry);
		recorders.delete(args.telemetry);
		await recorder?.close?.();
	},
	/** The span, event, and metric vocabularies pi-durable and pi-ai record. */
	"telemetry.schemas": () => ({ durable: DURABLE_TELEMETRY_SCHEMA, ai: AI_TELEMETRY_SCHEMA }),
});
