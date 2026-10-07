// Document writes from Swift patch the draft in place, so each commit stores a small delta.
import assert from "node:assert/strict";
import { test } from "node:test";
import { applyDeep } from "../src/bridge/docs.ts";

test("applyDeep makes the draft equal to the new value", () => {
	const draft: Record<string, unknown> = { a: 1, b: { c: [1, 2, 3], d: "x" }, gone: true };
	const next = { a: 2, b: { c: [1, 2, 4, 5], d: "x" }, added: { e: null } };
	applyDeep(draft, next);
	assert.deepEqual(draft, next);
});

test("applyDeep leaves unchanged subtrees untouched", () => {
	const unchanged = { deep: { list: [1, 2, 3] } };
	const changed = { value: 1 };
	const draft: Record<string, unknown> = { unchanged, changed };
	applyDeep(draft, { unchanged: { deep: { list: [1, 2, 3] } }, changed: { value: 2 } });
	assert.equal(draft.unchanged, unchanged, "an equal subtree keeps its object");
	assert.equal(draft.changed, changed, "a changed object is patched in place, not replaced");
	assert.deepEqual(changed, { value: 2 });
});

test("applyDeep shortens and grows arrays in place", () => {
	const list = [1, 2, 3, 4];
	const draft: Record<string, unknown> = { list };
	applyDeep(draft, { list: [1, 9] });
	assert.equal(draft.list, list);
	assert.deepEqual(list, [1, 9]);
	applyDeep(draft, { list: [1, 9, 10] });
	assert.deepEqual(list, [1, 9, 10]);
});
