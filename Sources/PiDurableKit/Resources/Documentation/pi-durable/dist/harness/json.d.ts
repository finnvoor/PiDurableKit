import type { JsonValue } from "@earendil-works/chord";
type JsonContainer = Record<string, JsonValue> | JsonValue[];
/**
 * Assign `value` at `target[key]` leaf by leaf. Chord records a container assignment as one full set and only emits an
 * append when a string leaf is reassigned with a longer string, so writing the partial whole would store and publish the
 * complete message on every flush.
 */
export declare function assignJson(target: JsonContainer, key: string | number, value: JsonValue): void;
export {};
