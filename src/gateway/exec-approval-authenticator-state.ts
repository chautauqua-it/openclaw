import { randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { resolveStateDir } from "../config/paths.js";
import type { ExecApprovalRecord } from "./exec-approval-manager.js";

const STATE_VERSION = 1;
const STATE_FILENAME = "authenticator/pending-exec-approvals.json";

export type PersistedAuthenticatorApproval = {
  record: ExecApprovalRecord;
  matchCodeHash: string;
};

type AuthenticatorApprovalState = {
  version: typeof STATE_VERSION;
  approvals: PersistedAuthenticatorApproval[];
};

function isPersistedApproval(
  value: unknown,
  nowMs: number,
): value is PersistedAuthenticatorApproval {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }
  const candidate = value as Partial<PersistedAuthenticatorApproval>;
  const record = candidate.record;
  return Boolean(
    record &&
    typeof record.id === "string" &&
    record.id.length > 0 &&
    typeof record.createdAtMs === "number" &&
    typeof record.expiresAtMs === "number" &&
    record.expiresAtMs > nowMs &&
    record.request?.authenticator &&
    typeof candidate.matchCodeHash === "string" &&
    /^[a-f0-9]{64}$/.test(candidate.matchCodeHash),
  );
}

export class ExecApprovalAuthenticatorStateStore {
  private readonly statePath: string;
  private approvals = new Map<string, PersistedAuthenticatorApproval>();

  constructor(baseDir?: string) {
    this.statePath = path.join(baseDir ?? resolveStateDir(), STATE_FILENAME);
  }

  load(nowMs = Date.now()): PersistedAuthenticatorApproval[] {
    let raw: unknown = null;
    try {
      raw = JSON.parse(fs.readFileSync(this.statePath, "utf8")) as unknown;
    } catch {
      this.approvals.clear();
      return [];
    }
    const state = raw as Partial<AuthenticatorApprovalState>;
    if (state.version !== STATE_VERSION || !Array.isArray(state.approvals)) {
      this.approvals.clear();
      return [];
    }
    const valid = state.approvals.filter((entry) => isPersistedApproval(entry, nowMs));
    this.approvals = new Map(valid.map((entry) => [entry.record.id, entry]));
    if (valid.length !== state.approvals.length) {
      this.persist();
    }
    return valid;
  }

  put(entry: PersistedAuthenticatorApproval): void {
    if (!isPersistedApproval(entry, Date.now())) {
      throw new Error("invalid or expired authenticator approval state");
    }
    this.approvals.set(entry.record.id, entry);
    this.persist();
  }

  delete(id: string): void {
    if (this.approvals.delete(id)) {
      this.persist();
    }
  }

  private persist(): void {
    const stateDir = path.dirname(this.statePath);
    fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
    if (fs.lstatSync(stateDir).isSymbolicLink()) {
      throw new Error("refusing to persist authenticator state through a symlink");
    }
    const tempPath = `${this.statePath}.${process.pid}.${randomUUID()}.tmp`;
    try {
      fs.writeFileSync(
        tempPath,
        `${JSON.stringify({ version: STATE_VERSION, approvals: [...this.approvals.values()] }, null, 2)}\n`,
        { mode: 0o600, flag: "wx" },
      );
      fs.renameSync(tempPath, this.statePath);
      fs.chmodSync(this.statePath, 0o600);
    } finally {
      fs.rmSync(tempPath, { force: true });
    }
  }
}
