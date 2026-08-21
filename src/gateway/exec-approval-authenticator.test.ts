import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  buildExecApprovalAuthenticatorDigest,
  publicAuthenticatorRequest,
  verifyExecApprovalAuthenticatorProof,
  type ExecApprovalAuthenticatorRequest,
} from "./exec-approval-authenticator.js";

function fixture() {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const publicKeyDer = publicKey.export({ format: "der", type: "spki" });
  const personId = createHash("sha256").update(publicKeyDer).digest("hex");
  const enteredCode = "42";
  const request: ExecApprovalAuthenticatorRequest = {
    personId,
    initiatorDeviceId: "a".repeat(64),
    nonce: Buffer.alloc(32, 7).toString("base64"),
    action: {
      environment: "staging",
      tenant: "tenant-a",
      audience: "dtail-critical-gate",
      actionId: "service.restart",
      requestHash: "b".repeat(64),
    },
    target: "host-a/service-a",
    parameterSummary: "restart service-a",
    matchCodeDigits: 2,
    matchCodeHash: createHash("sha256").update(enteredCode).digest("hex"),
  };
  const digest = buildExecApprovalAuthenticatorDigest({
    request,
    personId,
    enteredCode,
    decision: "approve",
  });
  return {
    request,
    proof: {
      personId,
      enteredCode,
      publicKeyDer: publicKeyDer.toString("base64"),
      signatureDer: sign(null, digest, privateKey).toString("base64"),
    },
  };
}

describe("exec approval authenticator", () => {
  it("accepts a byte-compatible P-256 approval", () => {
    const { request, proof } = fixture();
    expect(verifyExecApprovalAuthenticatorProof({ request, proof, decision: "approve" })).toEqual({
      ok: true,
    });
  });

  it("fails closed on number, action, decision and self-approval changes", () => {
    const { request, proof } = fixture();
    expect(
      verifyExecApprovalAuthenticatorProof({
        request,
        proof: { ...proof, enteredCode: "41" },
        decision: "approve",
      }).ok,
    ).toBe(false);
    expect(
      verifyExecApprovalAuthenticatorProof({
        request: { ...request, action: { ...request.action, actionId: "other" } },
        proof,
        decision: "approve",
      }).ok,
    ).toBe(false);
    expect(verifyExecApprovalAuthenticatorProof({ request, proof, decision: "deny" }).ok).toBe(
      false,
    );
    expect(
      verifyExecApprovalAuthenticatorProof({
        request: { ...request, initiatorDeviceId: request.personId },
        proof,
        decision: "approve",
      }).ok,
    ).toBe(false);
  });

  it("never exposes the short-code verifier to clients", () => {
    const { request } = fixture();
    expect(publicAuthenticatorRequest(request)).not.toHaveProperty("matchCodeHash");
  });
});
