import { createHash, generateKeyPairSync, randomBytes, sign, type KeyObject } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { afterAll, describe, expect, it, vi } from "vitest";
import { createTrackedTempDirs } from "../../test-utils/tracked-temp-dirs.js";
import { ExecApprovalAuthenticatorStateStore } from "../exec-approval-authenticator-state.js";
import {
  buildExecApprovalAuthenticatorDigest,
  type ExecApprovalAuthenticatorProof,
  type ExecApprovalAuthenticatorRequest,
} from "../exec-approval-authenticator.js";
import { ExecApprovalManager } from "../exec-approval-manager.js";
import { createExecApprovalHandlers } from "./exec-approval.js";

const tempDirs = createTrackedTempDirs();

afterAll(async () => {
  await tempDirs.cleanup();
});

type Approver = {
  personId: string;
  privateKey: KeyObject;
  publicKeyDerBase64: string;
  authenticator: ExecApprovalAuthenticatorRequest;
  enteredCode: string;
};

function createApprover(enteredCode = "42"): Approver {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const publicKeyDer = publicKey.export({ type: "spki", format: "der" });
  const personId = createHash("sha256").update(publicKeyDer).digest("hex");
  return {
    personId,
    privateKey,
    publicKeyDerBase64: publicKeyDer.toString("base64"),
    enteredCode,
    authenticator: {
      personId,
      initiatorDeviceId: createHash("sha256").update(randomBytes(16)).digest("hex"),
      nonce: randomBytes(32).toString("base64"),
      action: {
        environment: "staging",
        tenant: "tenant-a",
        audience: "dtail-gate",
        actionId: "network.config.write",
        requestHash: "ab".repeat(32),
      },
      target: "watchguard-a",
      parameterSummary: "Modifica VLAN porta 12",
      matchCodeDigits: enteredCode.length,
      matchCodeHash: createHash("sha256").update(enteredCode, "utf8").digest("hex"),
    },
  };
}

function buildProof(
  approver: Approver,
  decision: "approve" | "deny",
  enteredCode = approver.enteredCode,
): ExecApprovalAuthenticatorProof {
  const digest = buildExecApprovalAuthenticatorDigest({
    request: approver.authenticator,
    personId: approver.personId,
    enteredCode,
    decision,
  });
  return {
    personId: approver.personId,
    enteredCode,
    signatureDer: sign(null, digest, approver.privateKey).toString("base64"),
    publicKeyDer: approver.publicKeyDerBase64,
  };
}

function createHarness(baseDir: string) {
  const manager = new ExecApprovalManager();
  const stateStore = new ExecApprovalAuthenticatorStateStore(baseDir);
  const handlers = createExecApprovalHandlers(manager, { authenticatorStateStore: stateStore });
  return { manager, stateStore, handlers };
}

type Handlers = ReturnType<typeof createHarness>["handlers"];

const noop = () => false;

function requestApproval(params: {
  handlers: Handlers;
  respond: ReturnType<typeof vi.fn>;
  broadcast: ReturnType<typeof vi.fn>;
  authenticator: ExecApprovalAuthenticatorRequest;
  timeoutMs?: number;
}): Promise<void> {
  return params.handlers["exec.approval.request"]({
    params: {
      command: "dtail network vlan set",
      timeoutMs: params.timeoutMs ?? 3_000,
      twoPhase: true,
      authenticator: params.authenticator,
    },
    respond: params.respond,
    context: { broadcast: params.broadcast, hasExecApprovalClients: () => true },
    client: null,
    req: { id: "req-request", type: "req", method: "exec.approval.request" },
    isWebchatConnect: noop,
  } as never) as Promise<void>;
}

async function resolveApproval(params: {
  handlers: Handlers;
  respond: ReturnType<typeof vi.fn>;
  id: string;
  decision: "approve" | "deny";
  proof: ExecApprovalAuthenticatorProof;
}): Promise<void> {
  await (params.handlers["exec.approval.resolve"]({
    params: { id: params.id, decision: params.decision, authenticator: params.proof },
    respond: params.respond,
    context: { broadcast: () => {} },
    client: null,
    req: { id: "req-resolve", type: "req", method: "exec.approval.resolve" },
    isWebchatConnect: noop,
  } as never) as Promise<void>);
}

async function drainTicks(): Promise<void> {
  for (let i = 0; i < 20; i += 1) {
    await Promise.resolve();
  }
}

function acceptedId(respond: ReturnType<typeof vi.fn>): string {
  expect(respond).toHaveBeenCalledTimes(1);
  const payload = respond.mock.calls[0]?.[1] as { status?: string; id?: string };
  expect(payload.status).toBe("accepted");
  expect(typeof payload.id).toBe("string");
  return payload.id as string;
}

function statePath(baseDir: string): string {
  return path.join(baseDir, "authenticator", "pending-exec-approvals.json");
}

describe("exec approval authenticator lifecycle", () => {
  it("survives a gateway restart and enforces one-shot grants", async () => {
    const baseDir = await tempDirs.make("authenticator-lifecycle-");
    const approver = createApprover();
    const first = createHarness(baseDir);
    const requestRespond = vi.fn();
    const broadcast = vi.fn();
    const requestDone = requestApproval({
      handlers: first.handlers,
      respond: requestRespond,
      broadcast,
      authenticator: approver.authenticator,
    });
    await drainTicks();
    const approvalId = acceptedId(requestRespond);

    // The persisted state must exist, and neither it in broadcast form nor the
    // requested event may leak the match-code hash (it is code-equivalent).
    expect(fs.existsSync(statePath(baseDir))).toBe(true);
    const requestedEvent = broadcast.mock.calls.find(
      (call) => call[0] === "exec.approval.requested",
    )?.[1] as { request: { authenticator?: Record<string, unknown> } };
    expect(requestedEvent.request.authenticator).toBeDefined();
    expect(requestedEvent.request.authenticator).not.toHaveProperty("matchCodeHash");

    // Simulated restart: fresh manager + handlers rebuilt only from disk state.
    const second = createHarness(baseDir);
    const restoredEntries = second.stateStore.load();
    expect(restoredEntries).toHaveLength(1);
    const restoredHashes = new Map<string, string>();
    let restoredDecision: Promise<unknown> | null = null;
    for (const entry of restoredEntries) {
      restoredDecision = second.manager.register(
        entry.record,
        entry.record.expiresAtMs - Date.now(),
      );
      restoredHashes.set(entry.record.id, entry.matchCodeHash);
    }
    const restartedHandlers = createExecApprovalHandlers(second.manager, {
      authenticatorStateStore: second.stateStore,
      restoredAuthenticatorCodeHashes: restoredHashes,
    });

    // A wrong number-matching code must fail without consuming the approval.
    const wrongCodeRespond = vi.fn();
    await resolveApproval({
      handlers: restartedHandlers,
      respond: wrongCodeRespond,
      id: approvalId,
      decision: "approve",
      proof: buildProof(approver, "approve", "99"),
    });
    expect(wrongCodeRespond).toHaveBeenCalledWith(
      false,
      undefined,
      expect.objectContaining({ message: expect.stringContaining("mismatch") }),
    );
    expect(second.manager.getSnapshot(approvalId)?.resolvedAtMs).toBeUndefined();

    // Valid signed approval resolves to allow-once after the restart.
    const approveRespond = vi.fn();
    await resolveApproval({
      handlers: restartedHandlers,
      respond: approveRespond,
      id: approvalId,
      decision: "approve",
      proof: buildProof(approver, "approve"),
    });
    expect(approveRespond).toHaveBeenCalledWith(true, { ok: true }, undefined);
    await expect(restoredDecision).resolves.toBe("allow-once");

    // Joint cleanup: verifier hash and persisted state are gone, so a replay
    // of the very same valid proof fails closed instead of re-granting.
    expect(second.stateStore.load()).toHaveLength(0);
    const replayRespond = vi.fn();
    await resolveApproval({
      handlers: restartedHandlers,
      respond: replayRespond,
      id: approvalId,
      decision: "approve",
      proof: buildProof(approver, "approve"),
    });
    expect(replayRespond).toHaveBeenCalledWith(
      false,
      undefined,
      expect.objectContaining({
        message: expect.stringMatching(/unknown or expired approval id|unavailable/),
      }),
    );

    first.manager.expire(approvalId, "test-cleanup");
    await requestDone;
  });

  it("verifies a signed deny end-to-end and clears joint state", async () => {
    const baseDir = await tempDirs.make("authenticator-lifecycle-");
    const approver = createApprover();
    const { handlers, manager, stateStore } = createHarness(baseDir);
    const requestRespond = vi.fn();
    const requestDone = requestApproval({
      handlers,
      respond: requestRespond,
      broadcast: vi.fn(),
      authenticator: approver.authenticator,
    });
    await drainTicks();
    const approvalId = acceptedId(requestRespond);

    // A proof signed for "approve" must not be replayable as a deny.
    const crossDecisionRespond = vi.fn();
    await resolveApproval({
      handlers,
      respond: crossDecisionRespond,
      id: approvalId,
      decision: "deny",
      proof: buildProof(approver, "approve"),
    });
    expect(crossDecisionRespond).toHaveBeenCalledWith(
      false,
      undefined,
      expect.objectContaining({ message: expect.stringContaining("signature") }),
    );

    const denyRespond = vi.fn();
    await resolveApproval({
      handlers,
      respond: denyRespond,
      id: approvalId,
      decision: "deny",
      proof: buildProof(approver, "deny"),
    });
    expect(denyRespond).toHaveBeenCalledWith(true, { ok: true }, undefined);
    await requestDone;
    const finalPayload = requestRespond.mock.calls[1]?.[1] as { decision?: string };
    expect(finalPayload.decision).toBe("deny");
    expect(manager.getSnapshot(approvalId)?.decision).toBe("deny");
    expect(stateStore.load()).toHaveLength(0);
  });

  it("expires unresolved approvals fail-closed and rejects late proofs", async () => {
    const baseDir = await tempDirs.make("authenticator-lifecycle-");
    const approver = createApprover();
    const { handlers, stateStore } = createHarness(baseDir);
    const requestRespond = vi.fn();
    const requestDone = requestApproval({
      handlers,
      respond: requestRespond,
      broadcast: vi.fn(),
      authenticator: approver.authenticator,
      timeoutMs: 40,
    });
    await drainTicks();
    const approvalId = acceptedId(requestRespond);
    expect(stateStore.load()).toHaveLength(1);

    await requestDone;
    const finalPayload = requestRespond.mock.calls[1]?.[1] as { decision?: unknown };
    expect(finalPayload.decision).toBeNull();
    expect(stateStore.load()).toHaveLength(0);

    const lateRespond = vi.fn();
    await resolveApproval({
      handlers,
      respond: lateRespond,
      id: approvalId,
      decision: "approve",
      proof: buildProof(approver, "approve"),
    });
    expect(lateRespond.mock.calls[0]?.[0]).toBe(false);
  });
});
