import fs from "node:fs";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { createTrackedTempDirs } from "../test-utils/tracked-temp-dirs.js";
import { ExecApprovalAuthenticatorStateStore } from "./exec-approval-authenticator-state.js";
import type { ExecApprovalRecord } from "./exec-approval-manager.js";

const tempDirs = createTrackedTempDirs();

afterEach(async () => {
  await tempDirs.cleanup();
});

function record(id: string, expiresAtMs: number): ExecApprovalRecord {
  return {
    id,
    createdAtMs: 1_000,
    expiresAtMs,
    request: {
      command: "critical action",
      authenticator: {
        personId: "a".repeat(64),
        initiatorDeviceId: "b".repeat(64),
        nonce: Buffer.alloc(32).toString("base64"),
        action: {
          environment: "staging",
          tenant: "tenant-a",
          audience: "gateway",
          actionId: "network.config.apply",
          requestHash: "c".repeat(64),
        },
        target: "device-a",
        parameterSummary: "apply reviewed diff",
        matchCodeDigits: 2,
      },
    },
  };
}

describe("ExecApprovalAuthenticatorStateStore", () => {
  it("atomically persists and reloads a pending record with its verifier", async () => {
    const baseDir = await tempDirs.make("authenticator-state-");
    const now = Date.now();
    const store = new ExecApprovalAuthenticatorStateStore(baseDir);
    store.put({ record: record("approval-1", now + 20_000), matchCodeHash: "d".repeat(64) });

    expect(new ExecApprovalAuthenticatorStateStore(baseDir).load(now + 10_000)).toEqual([
      expect.objectContaining({
        record: expect.objectContaining({ id: "approval-1" }),
        matchCodeHash: "d".repeat(64),
      }),
    ]);
    const statePath = path.join(baseDir, "authenticator/pending-exec-approvals.json");
    expect(fs.statSync(statePath).mode & 0o777).toBe(0o600);
    expect(fs.readdirSync(path.dirname(statePath)).filter((name) => name.endsWith(".tmp"))).toEqual(
      [],
    );
  });

  it("prunes expired state and fails closed for malformed files", async () => {
    const baseDir = await tempDirs.make("authenticator-state-");
    const now = Date.now();
    const statePath = path.join(baseDir, "authenticator/pending-exec-approvals.json");
    const store = new ExecApprovalAuthenticatorStateStore(baseDir);
    store.put({ record: record("expired", now + 20_000), matchCodeHash: "d".repeat(64) });
    expect(new ExecApprovalAuthenticatorStateStore(baseDir).load(now + 20_001)).toEqual([]);

    fs.writeFileSync(statePath, "{invalid", "utf8");
    expect(new ExecApprovalAuthenticatorStateStore(baseDir).load(now + 10_000)).toEqual([]);
  });

  it("deletes the verifier together with its approval", async () => {
    const baseDir = await tempDirs.make("authenticator-state-");
    const now = Date.now();
    const store = new ExecApprovalAuthenticatorStateStore(baseDir);
    store.put({ record: record("approval-1", now + 20_000), matchCodeHash: "d".repeat(64) });
    store.delete("approval-1");
    expect(new ExecApprovalAuthenticatorStateStore(baseDir).load(now + 10_000)).toEqual([]);
  });

  it("refuses a symlinked authenticator state directory", async () => {
    const baseDir = await tempDirs.make("authenticator-state-");
    const outsideDir = await tempDirs.make("authenticator-state-outside-");
    const now = Date.now();
    fs.symlinkSync(outsideDir, path.join(baseDir, "authenticator"), "dir");

    expect(() =>
      new ExecApprovalAuthenticatorStateStore(baseDir).put({
        record: record("approval-1", now + 20_000),
        matchCodeHash: "d".repeat(64),
      }),
    ).toThrow(/symlink/);
    expect(fs.readdirSync(outsideDir)).toEqual([]);
  });
});
