import { test } from "node:test";
import assert from "node:assert/strict";
import { extractImportToken } from "./token.ts";

test("extracts a valid token from the envelope recipient", () => {
  assert.equal(
    extractImportToken("t-0123456789abcdef0123456789abcdef@plans.tripto.navbytes.io"),
    "0123456789abcdef0123456789abcdef",
  );
});

test("lowercases the local part before matching", () => {
  assert.equal(
    extractImportToken("T-0123456789ABCDEF0123456789ABCDEF@plans.tripto.navbytes.io"),
    "0123456789abcdef0123456789abcdef",
  );
});

test("rejects an address with no t- prefix", () => {
  assert.equal(extractImportToken("info@plans.tripto.navbytes.io"), null);
});

test("rejects an address with no @ at all", () => {
  assert.equal(extractImportToken("t-0123456789abcdef0123456789abcdef"), null);
});

test("rejects a token with non-hex characters", () => {
  assert.equal(extractImportToken("t-not-a-real-token@plans.tripto.navbytes.io"), null);
});

test("rejects an empty local part after the prefix", () => {
  assert.equal(extractImportToken("t-@plans.tripto.navbytes.io"), null);
});

test("rejects a token shorter than the pattern's floor", () => {
  assert.equal(extractImportToken("t-abc123@plans.tripto.navbytes.io"), null);
});

test("accepts a token at the pattern's upper slack (64 hex chars)", () => {
  const token = "a".repeat(64);
  assert.equal(extractImportToken(`t-${token}@plans.tripto.navbytes.io`), token);
});
