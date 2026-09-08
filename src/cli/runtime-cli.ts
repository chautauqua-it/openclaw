import fs from "node:fs";
import type { Command } from "commander";
import { z } from "zod";
import { danger } from "../globals.js";
import {
  CANONICAL_WRITER_SCOPES,
  evaluateDualRuntimeReadiness,
  type DualRuntimeReadinessResult,
  type DualRuntimeTopology,
} from "../infra/dual-runtime-readiness.js";
import { defaultRuntime } from "../runtime.js";
import { normalizeOptionalString } from "../shared/string-coerce.js";

type RuntimeReadinessOptions = {
  config?: string;
  json?: boolean;
};

const WriterScopeSchema = z.enum(CANONICAL_WRITER_SCOPES);

const FencingLeaseConfigSchema = z
  .object({
    backend: z.string(),
    leaseTtlMs: z.number(),
    renewalIntervalMs: z.number(),
    takeoverGraceMs: z.number(),
  })
  .strict();

const RuntimeNodeConfigSchema = z
  .object({
    nodeId: z.string(),
    clusterId: z.string(),
    executionEnabled: z.boolean(),
  })
  .strict();

const WriterOwnerAssignmentSchema = z
  .object({
    scope: WriterScopeSchema,
    nodeId: z.string(),
    enabled: z.boolean(),
    fencing: FencingLeaseConfigSchema,
  })
  .strict();

const LeaseStateSchema = z
  .object({
    scope: WriterScopeSchema,
    ownerNodeId: z.string(),
    acquiredAtMs: z.number(),
    expiresAtMs: z.number(),
  })
  .strict();

const TakeoverAttemptSchema = z
  .object({
    scope: WriterScopeSchema,
    requestingNodeId: z.string(),
    requestedAtMs: z.number(),
  })
  .strict();

// Structural (shape/type) validation only. Domain rules (positive TTLs,
// renewal < TTL, exactly-one-owner, etc.) stay inside evaluateDualRuntimeReadiness
// and surface as ordinary "not ready" issues (exit 1), not config errors (exit 2).
const DualRuntimeTopologyConfigSchema = z
  .object({
    nodes: z.array(RuntimeNodeConfigSchema),
    writers: z.array(WriterOwnerAssignmentSchema),
    leases: z.array(LeaseStateSchema).optional(),
    takeoverAttempts: z.array(TakeoverAttemptSchema).optional(),
  })
  .strict();

function readTopologyConfigFile(configPath: string): DualRuntimeTopology {
  let raw: string;
  try {
    raw = fs.readFileSync(configPath, "utf8");
  } catch (err) {
    throw new Error(
      `Unable to read config file "${configPath}": ${err instanceof Error ? err.message : String(err)}`,
      { cause: err },
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new Error(
      `Config file "${configPath}" is not valid JSON: ${err instanceof Error ? err.message : String(err)}`,
      { cause: err },
    );
  }

  const result = DualRuntimeTopologyConfigSchema.safeParse(parsed);
  if (!result.success) {
    const details = result.error.issues
      .map(
        (issue) => `${issue.path.length > 0 ? issue.path.join(".") : "<root>"}: ${issue.message}`,
      )
      .join("; ");
    throw new Error(
      `Config file "${configPath}" does not match the expected dual-runtime topology shape: ${details}`,
    );
  }
  return result.data;
}

function printHumanReadinessReport(result: DualRuntimeReadinessResult): void {
  defaultRuntime.log(
    result.ready
      ? "Dual-runtime readiness: READY"
      : `Dual-runtime readiness: NOT READY (${result.issues.length} issue(s))`,
  );
  for (const issue of result.issues) {
    defaultRuntime.log(`- [${issue.code}] ${issue.path}: ${issue.message}`);
  }
  defaultRuntime.log(
    `Nodes: ${result.summary.nodeCount} (execution-enabled: ${result.summary.executionEnabledNodeIds.length})`,
  );
}

export function registerRuntimeCli(program: Command): Command {
  const runtime = program.command("runtime").description("Dual-runtime topology tools");

  runtime
    .command("readiness")
    .description("Validate a dual-runtime topology config for single-writer readiness")
    .option("--config <file>", "Path to a dual-runtime topology JSON config file")
    .option("--json", "Output JSON", false)
    .action(async (opts: RuntimeReadinessOptions) => {
      const configPath = normalizeOptionalString(opts.config);
      if (!configPath) {
        defaultRuntime.error(danger("--config <file> is required"));
        defaultRuntime.exit(2);
        return;
      }

      let topology: DualRuntimeTopology;
      try {
        topology = readTopologyConfigFile(configPath);
      } catch (err) {
        defaultRuntime.error(danger(err instanceof Error ? err.message : String(err)));
        defaultRuntime.exit(2);
        return;
      }

      const result = evaluateDualRuntimeReadiness(topology);

      if (opts.json) {
        defaultRuntime.writeJson(result);
      } else {
        printHumanReadinessReport(result);
      }

      if (!result.ready) {
        defaultRuntime.exit(1);
      }
    });

  return runtime;
}
