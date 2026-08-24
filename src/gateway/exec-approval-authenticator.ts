import { createHash, createPublicKey, timingSafeEqual, verify } from "node:crypto";

export type ExecApprovalAuthenticatorAction = {
  environment: string;
  tenant: string;
  audience: string;
  actionId: string;
  requestHash: string;
};

export type ExecApprovalAuthenticatorRequest = {
  personId: string;
  initiatorDeviceId: string;
  nonce: string;
  action: ExecApprovalAuthenticatorAction;
  target: string;
  parameterSummary: string;
  matchCodeDigits: number;
  matchCodeHash: string;
};

export type ExecApprovalAuthenticatorProof = {
  personId: string;
  enteredCode: string;
  signatureDer: string;
  publicKeyDer: string;
};

// Anti-fatigue guard mirroring dtail-agent internal/authn: a cooldown between
// prompts to the same person plus a volume cap per rolling window, enforced
// BEFORE a prompt is created so an attacker cannot even cause push spam.
export class ExecApprovalAuthenticatorFatigueGuard {
  private readonly cooldownMs: number;
  private readonly maxPromptsPerWindow: number;
  private readonly windowMs: number;
  private readonly prompts = new Map<string, number[]>();

  constructor(opts?: { cooldownMs?: number; maxPromptsPerWindow?: number; windowMs?: number }) {
    this.cooldownMs = opts?.cooldownMs ?? 5_000;
    this.maxPromptsPerWindow = opts?.maxPromptsPerWindow ?? 5;
    this.windowMs = opts?.windowMs ?? 60_000;
  }

  check(personId: string, nowMs = Date.now()): { ok: true } | { ok: false; reason: string } {
    const pruned = (this.prompts.get(personId) ?? []).filter((t) => t > nowMs - this.windowMs);
    this.prompts.set(personId, pruned);
    const last = pruned.at(-1);
    if (last !== undefined && nowMs - last < this.cooldownMs) {
      return { ok: false, reason: "authenticator prompt cooldown active (anti-fatigue)" };
    }
    if (pruned.length >= this.maxPromptsPerWindow) {
      return { ok: false, reason: "too many authenticator prompts in window (anti-fatigue)" };
    }
    pruned.push(nowMs);
    return { ok: true };
  }
}

function lengthPrefixed(value: string): Buffer {
  const body = Buffer.from(value, "utf8");
  const prefix = Buffer.allocUnsafe(4);
  prefix.writeUInt32BE(body.length);
  return Buffer.concat([prefix, body]);
}

function canonicalAction(action: ExecApprovalAuthenticatorAction): Buffer {
  return Buffer.concat(
    [action.environment, action.tenant, action.audience, action.actionId, action.requestHash].map(
      lengthPrefixed,
    ),
  );
}

function decodeBase64Strict(value: string): Buffer | null {
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value) || value.length % 4 !== 0) {
    return null;
  }
  const decoded = Buffer.from(value, "base64");
  return decoded.toString("base64") === value ? decoded : null;
}

function isHex64(value: string): boolean {
  return /^[a-f0-9]{64}$/.test(value);
}

export function publicAuthenticatorRequest(request: ExecApprovalAuthenticatorRequest) {
  const { matchCodeHash: _matchCodeHash, ...publicFields } = request;
  return publicFields;
}

export function buildExecApprovalAuthenticatorDigest(params: {
  request: ExecApprovalAuthenticatorRequest;
  personId: string;
  enteredCode: string;
  decision: "approve" | "deny";
}): Buffer {
  const nonce = decodeBase64Strict(params.request.nonce);
  if (!nonce || nonce.length !== 32) {
    throw new Error("invalid authenticator nonce");
  }
  return createHash("sha256")
    .update(Buffer.from([0x02]))
    .update(params.personId, "utf8")
    .update(params.request.initiatorDeviceId, "utf8")
    .update(nonce)
    .update(params.enteredCode, "utf8")
    .update(params.decision, "utf8")
    .update(canonicalAction(params.request.action))
    .digest();
}

export function verifyExecApprovalAuthenticatorProof(params: {
  request: ExecApprovalAuthenticatorRequest;
  proof: ExecApprovalAuthenticatorProof;
  decision: "approve" | "deny";
}): { ok: true } | { ok: false; reason: string } {
  const { request, proof, decision } = params;
  if (request.personId === request.initiatorDeviceId) {
    return { ok: false, reason: "approver may not be the initiating device" };
  }
  if (proof.personId !== request.personId || !isHex64(proof.personId)) {
    return { ok: false, reason: "person binding mismatch" };
  }
  if (!new RegExp(`^[0-9]{${request.matchCodeDigits}}$`).test(proof.enteredCode)) {
    return { ok: false, reason: "invalid number-matching code" };
  }
  const actualCodeHash = createHash("sha256").update(proof.enteredCode, "utf8").digest();
  const expectedCodeHash = Buffer.from(request.matchCodeHash, "hex");
  if (expectedCodeHash.length !== 32 || !timingSafeEqual(actualCodeHash, expectedCodeHash)) {
    return { ok: false, reason: "number-matching code mismatch" };
  }
  const nonce = decodeBase64Strict(request.nonce);
  const publicKeyDer = decodeBase64Strict(proof.publicKeyDer);
  const signatureDer = decodeBase64Strict(proof.signatureDer);
  if (!nonce || nonce.length !== 32 || !publicKeyDer || !signatureDer) {
    return { ok: false, reason: "malformed authenticator proof" };
  }
  const derivedPersonId = createHash("sha256").update(publicKeyDer).digest("hex");
  if (derivedPersonId !== proof.personId) {
    return { ok: false, reason: "public key does not match person" };
  }
  try {
    const publicKey = createPublicKey({ key: publicKeyDer, format: "der", type: "spki" });
    if (publicKey.asymmetricKeyType !== "ec") {
      return { ok: false, reason: "authenticator key must be P-256" };
    }
    const details = publicKey.asymmetricKeyDetails;
    if (details?.namedCurve !== "prime256v1") {
      return { ok: false, reason: "authenticator key must be P-256" };
    }
    const digest = buildExecApprovalAuthenticatorDigest({
      request,
      personId: proof.personId,
      enteredCode: proof.enteredCode,
      decision,
    });
    return verify(null, digest, publicKey, signatureDer)
      ? { ok: true }
      : { ok: false, reason: "invalid authenticator signature" };
  } catch {
    return { ok: false, reason: "malformed authenticator public key" };
  }
}
