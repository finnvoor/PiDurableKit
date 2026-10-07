import { type JsonValue } from "@earendil-works/chord";
import type { Op } from "@earendil-works/chord/delta";
import type { CheckpointInfo, CommonDocDefinition, ConversationDocFamilyToken, ConversationDocToken, DocumentAddress, DocumentCreate, DocumentId, DocumentRecord, DocumentSemantics, JsonObject, LatestConversationSemantics, RewindableConversationDocFamilyToken, RewindableConversationDocToken, RewindableConversationSemantics, SessionDocFamilyToken, SessionDocToken, StoredDocument, TaskDocFamilyToken, TaskDocToken } from "./types.ts";
type FamilyInput<T extends JsonObject, I extends JsonValue> = Omit<CommonDocDefinition<T>, "initial"> & {
    readonly family: true;
    initial(seed: I): T;
};
/** Define a Session-scoped singleton document. */
export declare function defineDoc<T extends JsonObject>(definition: CommonDocDefinition<T> & {
    readonly scope: "session";
}): SessionDocToken<T>;
/** Define a latest-only conversation singleton document. */
export declare function defineDoc<T extends JsonObject>(definition: CommonDocDefinition<T> & LatestConversationSemantics): ConversationDocToken<T>;
/** Define a rewindable conversation singleton document. */
export declare function defineDoc<T extends JsonObject>(definition: CommonDocDefinition<T> & RewindableConversationSemantics): RewindableConversationDocToken<T>;
/** Define a task-scoped singleton document. */
export declare function defineDoc<T extends JsonObject>(definition: CommonDocDefinition<T> & {
    readonly scope: "task";
}): TaskDocToken<T>;
/** Define a Session-scoped document family. */
export declare function defineDocFamily<T extends JsonObject, I extends JsonValue>(definition: FamilyInput<T, I> & {
    readonly scope: "session";
}): SessionDocFamilyToken<T, I>;
/** Define a latest-only conversation document family. */
export declare function defineDocFamily<T extends JsonObject, I extends JsonValue>(definition: FamilyInput<T, I> & LatestConversationSemantics): ConversationDocFamilyToken<T, I>;
/** Define a rewindable conversation document family. */
export declare function defineDocFamily<T extends JsonObject, I extends JsonValue>(definition: FamilyInput<T, I> & RewindableConversationSemantics): RewindableConversationDocFamilyToken<T, I>;
/** Define a task-scoped document family. */
export declare function defineDocFamily<T extends JsonObject, I extends JsonValue>(definition: FamilyInput<T, I> & {
    readonly scope: "task";
}): TaskDocFamilyToken<T, I>;
/** Erased definition shape used by the Session after overload resolution. */
export type AnyDocDefinition = DocumentSemantics & {
    readonly kind: string;
    readonly version: number;
    readonly family?: true;
    initial(seed?: JsonValue): JsonObject;
    migrate?(value: JsonObject, fromVersion: number): JsonObject;
    checkpointWhen?(value: Readonly<JsonObject>, ops: readonly Op[], info: CheckpointInfo): boolean;
};
/** Erased singleton or family token. */
export type AnyDocToken = {
    readonly definition: AnyDocDefinition;
};
/** Logical address plus its string identity for maps. */
export type ResolvedAddress = {
    readonly address: DocumentAddress;
    readonly id: string;
    readonly nextArgument: number;
};
/** Resolve an overloaded argument list and return the index after the owner and family key. */
export declare function resolveAddress(definition: AnyDocDefinition, args: readonly unknown[]): ResolvedAddress;
/** Stable string identity of one logical address. */
export declare function addressId(address: DocumentAddress): string;
/** Build the storage create record for a new incarnation at an address. */
export declare function documentCreate(definition: AnyDocDefinition, address: DocumentAddress, id: DocumentId): DocumentCreate;
/** Reject typed access whose token disagrees with the persisted scope, history, or fork semantics. */
export declare function checkRecordScope(definition: AnyDocDefinition, record: DocumentCreate | DocumentRecord): void;
/** Reject typed access to a stored version the supplied definition cannot use. */
export declare function checkRecordVersion(definition: AnyDocDefinition, record: DocumentCreate | DocumentRecord, version: number): void;
/** Validate and materialize a detached stored value for typed access. */
export declare function materializeDocument(definition: AnyDocDefinition, stored: StoredDocument): JsonObject;
/** Validate and materialize one detached value before its first persisted incarnation. */
export declare function materializeDocumentValue(definition: AnyDocDefinition, record: DocumentCreate | DocumentRecord, version: number, value: JsonObject): JsonObject;
export {};
