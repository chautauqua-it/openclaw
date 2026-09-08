/**
 * Pure, deterministic readiness validator for an OpenClaw / IanuaO topology
 * that spans two runtime systems (e.g. a Mac mini and a cluster node).
 *
 * Both nodes may run execution concurrently; this module only guards the
 * narrower invariant that every writer-sensitive resource ("writer scope")
 * has exactly one enabled owner at a time, backed by a valid fencing lease
 * configuration, and that lease takeover cannot race an unexpired lease.
 *
 * No I/O, network access, or environmental clock reads: all timestamps are
 * plain milliseconds supplied by the caller.
 */

export const CANONICAL_WRITER_SCOPES = [
  "channel_ingest",
  "scheduler",
  "session_delivery",
  "shared_memory",
] as const;

export type WriterScope = (typeof CANONICAL_WRITER_SCOPES)[number];

export type RuntimeNodeConfig = {
  nodeId: string;
  clusterId: string;
  executionEnabled: boolean;
};

export type FencingLeaseConfig = {
  backend: string;
  leaseTtlMs: number;
  renewalIntervalMs: number;
  takeoverGraceMs: number;
};

export type WriterOwnerAssignment = {
  scope: WriterScope;
  nodeId: string;
  enabled: boolean;
  fencing: FencingLeaseConfig;
};

export type LeaseState = {
  scope: WriterScope;
  ownerNodeId: string;
  acquiredAtMs: number;
  expiresAtMs: number;
};

export type TakeoverAttempt = {
  scope: WriterScope;
  requestingNodeId: string;
  requestedAtMs: number;
};

export type DualRuntimeTopology = {
  nodes: RuntimeNodeConfig[];
  writers: WriterOwnerAssignment[];
  leases?: LeaseState[];
  takeoverAttempts?: TakeoverAttempt[];
};

export type ReadinessIssueCode =
  | "node.duplicateId"
  | "node.emptyClusterId"
  | "node.insufficientExecutionNodes"
  | "writer.missingOwner"
  | "writer.multipleOwners"
  | "writer.unknownScope"
  | "writer.unknownNode"
  | "writer.ownerNodeExecutionDisabled"
  | "fencing.emptyBackend"
  | "fencing.invalidLeaseTtl"
  | "fencing.invalidRenewalInterval"
  | "fencing.invalidTakeoverGrace"
  | "fencing.renewalNotBeforeLeaseTtl"
  | "fencing.leaseTtlExceedsTakeoverGrace"
  | "takeover.leaseNotExpired";

export type ReadinessIssue = {
  code: ReadinessIssueCode;
  path: string;
  message: string;
};

export type WriterScopeSummary = {
  scope: WriterScope;
  ownerNodeId: string | null;
  enabledOwnerCount: number;
};

export type DualRuntimeReadinessSummary = {
  nodeCount: number;
  executionEnabledNodeIds: string[];
  writerScopes: WriterScopeSummary[];
};

export type DualRuntimeReadinessResult = {
  ready: boolean;
  issues: ReadinessIssue[];
  summary: DualRuntimeReadinessSummary;
};

function isPositiveFiniteNumber(value: number): boolean {
  return Number.isFinite(value) && value > 0;
}

function validateNodes(nodes: RuntimeNodeConfig[], issues: ReadinessIssue[]): Set<string> {
  const seenNodeIds = new Set<string>();
  const knownNodeIds = new Set<string>();
  nodes.forEach((node, index) => {
    const path = `nodes[${index}]`;
    if (!node.clusterId || node.clusterId.trim() === "") {
      issues.push({
        code: "node.emptyClusterId",
        path: `${path}.clusterId`,
        message: `Node "${node.nodeId}" has an empty clusterId.`,
      });
    }
    if (seenNodeIds.has(node.nodeId)) {
      issues.push({
        code: "node.duplicateId",
        path: `${path}.nodeId`,
        message: `Duplicate nodeId "${node.nodeId}"; nodeId must be unique across the topology.`,
      });
    }
    seenNodeIds.add(node.nodeId);
    knownNodeIds.add(node.nodeId);
  });
  return knownNodeIds;
}

function validateExecutionNodes(nodes: RuntimeNodeConfig[], issues: ReadinessIssue[]): Set<string> {
  const executionEnabledNodeIds = new Set(
    nodes.filter((node) => node.executionEnabled).map((node) => node.nodeId),
  );
  if (executionEnabledNodeIds.size < 2) {
    issues.push({
      code: "node.insufficientExecutionNodes",
      path: "nodes",
      message: `Dual-runtime readiness requires at least two execution-enabled nodes; found ${executionEnabledNodeIds.size}.`,
    });
  }
  return executionEnabledNodeIds;
}

function validateWriterOwnership(
  writers: WriterOwnerAssignment[],
  knownNodeIds: Set<string>,
  executionEnabledNodeIds: Set<string>,
  issues: ReadinessIssue[],
): Map<WriterScope, WriterOwnerAssignment[]> {
  const writersByScope = new Map<WriterScope, WriterOwnerAssignment[]>();
  for (const scope of CANONICAL_WRITER_SCOPES) {
    writersByScope.set(scope, []);
  }

  const canonicalScopes = new Set<WriterScope>(CANONICAL_WRITER_SCOPES);
  writers.forEach((writer, index) => {
    if (canonicalScopes.has(writer.scope)) {
      writersByScope.get(writer.scope)!.push(writer);
    } else {
      issues.push({
        code: "writer.unknownScope",
        path: `writers[${index}].scope`,
        message: `Writer scope "${writer.scope}" is not one of the canonical writer scopes.`,
      });
    }
    if (!knownNodeIds.has(writer.nodeId)) {
      issues.push({
        code: "writer.unknownNode",
        path: `writers[${index}].nodeId`,
        message: `Writer for scope "${writer.scope}" references unknown nodeId "${writer.nodeId}".`,
      });
    } else if (writer.enabled && !executionEnabledNodeIds.has(writer.nodeId)) {
      issues.push({
        code: "writer.ownerNodeExecutionDisabled",
        path: `writers[${index}].nodeId`,
        message: `Enabled writer for scope "${writer.scope}" is assigned to execution-disabled nodeId "${writer.nodeId}".`,
      });
    }
  });

  for (const scope of CANONICAL_WRITER_SCOPES) {
    const owners = writersByScope.get(scope)!;
    const enabledOwners = owners.filter((owner) => owner.enabled);
    const path = `writers[scope=${scope}]`;
    if (enabledOwners.length === 0) {
      issues.push({
        code: "writer.missingOwner",
        path,
        message: `Writer scope "${scope}" has no enabled owner; exactly one is required.`,
      });
    } else if (enabledOwners.length > 1) {
      issues.push({
        code: "writer.multipleOwners",
        path,
        message: `Writer scope "${scope}" has ${enabledOwners.length} enabled owners (${enabledOwners
          .map((owner) => owner.nodeId)
          .join(", ")}); exactly one is required.`,
      });
    }
  }

  return writersByScope;
}

function validateFencing(writers: WriterOwnerAssignment[], issues: ReadinessIssue[]): void {
  writers.forEach((writer, index) => {
    const path = `writers[${index}].fencing`;
    const fencing = writer.fencing;

    if (!fencing.backend || fencing.backend.trim() === "") {
      issues.push({
        code: "fencing.emptyBackend",
        path: `${path}.backend`,
        message: `Writer for scope "${writer.scope}" has an empty fencing backend.`,
      });
    }

    const validLeaseTtl = isPositiveFiniteNumber(fencing.leaseTtlMs);
    if (!validLeaseTtl) {
      issues.push({
        code: "fencing.invalidLeaseTtl",
        path: `${path}.leaseTtlMs`,
        message: `Writer for scope "${writer.scope}" has an invalid leaseTtlMs (${fencing.leaseTtlMs}); it must be a positive number.`,
      });
    }

    const validRenewalInterval = isPositiveFiniteNumber(fencing.renewalIntervalMs);
    if (!validRenewalInterval) {
      issues.push({
        code: "fencing.invalidRenewalInterval",
        path: `${path}.renewalIntervalMs`,
        message: `Writer for scope "${writer.scope}" has an invalid renewalIntervalMs (${fencing.renewalIntervalMs}); it must be a positive number.`,
      });
    }

    const validTakeoverGrace = isPositiveFiniteNumber(fencing.takeoverGraceMs);
    if (!validTakeoverGrace) {
      issues.push({
        code: "fencing.invalidTakeoverGrace",
        path: `${path}.takeoverGraceMs`,
        message: `Writer for scope "${writer.scope}" has an invalid takeoverGraceMs (${fencing.takeoverGraceMs}); it must be a positive number.`,
      });
    }

    if (
      validLeaseTtl &&
      validRenewalInterval &&
      !(fencing.renewalIntervalMs < fencing.leaseTtlMs)
    ) {
      issues.push({
        code: "fencing.renewalNotBeforeLeaseTtl",
        path: `${path}.renewalIntervalMs`,
        message: `Writer for scope "${writer.scope}" has renewalIntervalMs (${fencing.renewalIntervalMs}) that is not less than leaseTtlMs (${fencing.leaseTtlMs}).`,
      });
    }

    if (validLeaseTtl && validTakeoverGrace && !(fencing.leaseTtlMs <= fencing.takeoverGraceMs)) {
      issues.push({
        code: "fencing.leaseTtlExceedsTakeoverGrace",
        path: `${path}.takeoverGraceMs`,
        message: `Writer for scope "${writer.scope}" has leaseTtlMs (${fencing.leaseTtlMs}) greater than takeoverGraceMs (${fencing.takeoverGraceMs}).`,
      });
    }
  });
}

function validateTakeoverAttempts(
  takeoverAttempts: TakeoverAttempt[],
  leases: LeaseState[],
  issues: ReadinessIssue[],
): void {
  const leaseByScope = new Map<WriterScope, LeaseState>();
  for (const lease of leases) {
    leaseByScope.set(lease.scope, lease);
  }

  takeoverAttempts.forEach((attempt, index) => {
    const lease = leaseByScope.get(attempt.scope);
    if (!lease) {
      return;
    }
    if (attempt.requestedAtMs < lease.expiresAtMs) {
      issues.push({
        code: "takeover.leaseNotExpired",
        path: `takeoverAttempts[${index}]`,
        message: `Takeover of scope "${attempt.scope}" by "${attempt.requestingNodeId}" was requested at ${attempt.requestedAtMs}, before the current lease (held by "${lease.ownerNodeId}") expires at ${lease.expiresAtMs}.`,
      });
    }
  });
}

function buildSummary(
  nodes: RuntimeNodeConfig[],
  writersByScope: Map<WriterScope, WriterOwnerAssignment[]>,
): DualRuntimeReadinessSummary {
  return {
    nodeCount: nodes.length,
    executionEnabledNodeIds: nodes
      .filter((node) => node.executionEnabled)
      .map((node) => node.nodeId),
    writerScopes: CANONICAL_WRITER_SCOPES.map((scope) => {
      const enabledOwners = (writersByScope.get(scope) ?? []).filter((owner) => owner.enabled);
      return {
        scope,
        ownerNodeId: enabledOwners.length === 1 ? enabledOwners[0].nodeId : null,
        enabledOwnerCount: enabledOwners.length,
      };
    }),
  };
}

export function evaluateDualRuntimeReadiness(
  topology: DualRuntimeTopology,
): DualRuntimeReadinessResult {
  const issues: ReadinessIssue[] = [];
  const leases = topology.leases ?? [];
  const takeoverAttempts = topology.takeoverAttempts ?? [];

  const knownNodeIds = validateNodes(topology.nodes, issues);
  const executionEnabledNodeIds = validateExecutionNodes(topology.nodes, issues);
  const writersByScope = validateWriterOwnership(
    topology.writers,
    knownNodeIds,
    executionEnabledNodeIds,
    issues,
  );
  validateFencing(topology.writers, issues);
  validateTakeoverAttempts(takeoverAttempts, leases, issues);

  return {
    ready: issues.length === 0,
    issues,
    summary: buildSummary(topology.nodes, writersByScope),
  };
}
