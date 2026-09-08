import { describe, expect, it } from "vitest";
import {
  evaluateDualRuntimeReadiness,
  type DualRuntimeTopology,
  type FencingLeaseConfig,
  type RuntimeNodeConfig,
  type WriterOwnerAssignment,
} from "./dual-runtime-readiness.js";

function validFencing(overrides: Partial<FencingLeaseConfig> = {}): FencingLeaseConfig {
  return {
    backend: "redis",
    leaseTtlMs: 5_000,
    renewalIntervalMs: 1_000,
    takeoverGraceMs: 5_000,
    ...overrides,
  };
}

function macMiniNode(overrides: Partial<RuntimeNodeConfig> = {}): RuntimeNodeConfig {
  return {
    nodeId: "mac-mini",
    clusterId: "mac-mini-cluster",
    executionEnabled: true,
    ...overrides,
  };
}

function clusterNode(overrides: Partial<RuntimeNodeConfig> = {}): RuntimeNodeConfig {
  return {
    nodeId: "cluster-a",
    clusterId: "cluster-a-cluster",
    executionEnabled: true,
    ...overrides,
  };
}

function writer(overrides: Partial<WriterOwnerAssignment>): WriterOwnerAssignment {
  return {
    scope: "channel_ingest",
    nodeId: "mac-mini",
    enabled: true,
    fencing: validFencing(),
    ...overrides,
  };
}

function baseTopology(overrides: Partial<DualRuntimeTopology> = {}): DualRuntimeTopology {
  return {
    nodes: [macMiniNode(), clusterNode()],
    writers: [
      writer({ scope: "channel_ingest", nodeId: "mac-mini" }),
      writer({ scope: "scheduler", nodeId: "mac-mini" }),
      writer({ scope: "session_delivery", nodeId: "cluster-a" }),
      writer({ scope: "shared_memory", nodeId: "cluster-a" }),
    ],
    ...overrides,
  };
}

describe("evaluateDualRuntimeReadiness", () => {
  it("passes when both nodes are execution-enabled and writer scopes are split without collision", () => {
    const result = evaluateDualRuntimeReadiness(baseTopology());

    expect(result.ready).toBe(true);
    expect(result.issues).toEqual([]);
    expect(result.summary).toEqual({
      nodeCount: 2,
      executionEnabledNodeIds: ["mac-mini", "cluster-a"],
      writerScopes: [
        { scope: "channel_ingest", ownerNodeId: "mac-mini", enabledOwnerCount: 1 },
        { scope: "scheduler", ownerNodeId: "mac-mini", enabledOwnerCount: 1 },
        { scope: "session_delivery", ownerNodeId: "cluster-a", enabledOwnerCount: 1 },
        { scope: "shared_memory", ownerNodeId: "cluster-a", enabledOwnerCount: 1 },
      ],
    });
  });

  it("stops when a writer scope has two enabled owners", () => {
    const topology = baseTopology({
      writers: [
        writer({ scope: "channel_ingest", nodeId: "mac-mini" }),
        writer({ scope: "channel_ingest", nodeId: "cluster-a" }),
        writer({ scope: "scheduler", nodeId: "mac-mini" }),
        writer({ scope: "session_delivery", nodeId: "cluster-a" }),
        writer({ scope: "shared_memory", nodeId: "cluster-a" }),
      ],
    });

    const result = evaluateDualRuntimeReadiness(topology);

    expect(result.ready).toBe(false);
    expect(result.issues).toContainEqual(
      expect.objectContaining({
        code: "writer.multipleOwners",
        path: "writers[scope=channel_ingest]",
      }),
    );
    expect(result.summary.writerScopes[0]).toEqual({
      scope: "channel_ingest",
      ownerNodeId: null,
      enabledOwnerCount: 2,
    });
  });

  it("stops when a writer scope has no owner", () => {
    const topology = baseTopology({
      writers: [
        writer({ scope: "channel_ingest", nodeId: "mac-mini" }),
        writer({ scope: "scheduler", nodeId: "mac-mini" }),
        writer({ scope: "session_delivery", nodeId: "cluster-a" }),
      ],
    });

    const result = evaluateDualRuntimeReadiness(topology);

    expect(result.ready).toBe(false);
    expect(result.issues).toContainEqual(
      expect.objectContaining({
        code: "writer.missingOwner",
        path: "writers[scope=shared_memory]",
      }),
    );
    expect(result.summary.writerScopes[3]).toEqual({
      scope: "shared_memory",
      ownerNodeId: null,
      enabledOwnerCount: 0,
    });
  });

  it("stops when nodeId is duplicated", () => {
    const topology = baseTopology({
      nodes: [macMiniNode(), clusterNode({ nodeId: "mac-mini" })],
    });

    const result = evaluateDualRuntimeReadiness(topology);

    expect(result.ready).toBe(false);
    expect(result.issues).toContainEqual({
      code: "node.duplicateId",
      path: "nodes[1].nodeId",
      message: 'Duplicate nodeId "mac-mini"; nodeId must be unique across the topology.',
    });
  });

  it("stops when fewer than two nodes are execution-enabled", () => {
    const topology = baseTopology({
      nodes: [macMiniNode(), clusterNode({ executionEnabled: false })],
      writers: [
        writer({ scope: "channel_ingest", nodeId: "mac-mini" }),
        writer({ scope: "scheduler", nodeId: "mac-mini" }),
        writer({ scope: "session_delivery", nodeId: "mac-mini" }),
        writer({ scope: "shared_memory", nodeId: "mac-mini" }),
      ],
    });

    const result = evaluateDualRuntimeReadiness(topology);

    expect(result.ready).toBe(false);
    expect(result.issues).toContainEqual({
      code: "node.insufficientExecutionNodes",
      path: "nodes",
      message: "Dual-runtime readiness requires at least two execution-enabled nodes; found 1.",
    });
  });

  it("stops when an enabled writer is assigned to an execution-disabled node", () => {
    const topology = baseTopology({
      nodes: [macMiniNode(), clusterNode({ executionEnabled: false })],
    });

    const result = evaluateDualRuntimeReadiness(topology);

    expect(result.ready).toBe(false);
    expect(result.issues).toContainEqual({
      code: "writer.ownerNodeExecutionDisabled",
      path: "writers[2].nodeId",
      message:
        'Enabled writer for scope "session_delivery" is assigned to execution-disabled nodeId "cluster-a".',
    });
    expect(result.issues).toContainEqual(
      expect.objectContaining({
        code: "writer.ownerNodeExecutionDisabled",
        path: "writers[3].nodeId",
      }),
    );
  });

  it("stops on unsafe lease timing (renewal not before TTL, TTL beyond takeover grace)", () => {
    const topology = baseTopology({
      writers: [
        writer({
          scope: "channel_ingest",
          nodeId: "mac-mini",
          fencing: validFencing({ renewalIntervalMs: 5_000, leaseTtlMs: 5_000 }),
        }),
        writer({ scope: "scheduler", nodeId: "mac-mini" }),
        writer({ scope: "session_delivery", nodeId: "cluster-a" }),
        writer({
          scope: "shared_memory",
          nodeId: "cluster-a",
          fencing: validFencing({ leaseTtlMs: 6_000, takeoverGraceMs: 5_000 }),
        }),
      ],
    });

    const result = evaluateDualRuntimeReadiness(topology);

    expect(result.ready).toBe(false);
    expect(result.issues).toContainEqual(
      expect.objectContaining({
        code: "fencing.renewalNotBeforeLeaseTtl",
        path: "writers[0].fencing.renewalIntervalMs",
      }),
    );
    expect(result.issues).toContainEqual(
      expect.objectContaining({
        code: "fencing.leaseTtlExceedsTakeoverGrace",
        path: "writers[3].fencing.takeoverGraceMs",
      }),
    );
  });

  it("stops when a takeover is requested before the current lease expires", () => {
    const topology = baseTopology({
      leases: [
        { scope: "channel_ingest", ownerNodeId: "mac-mini", acquiredAtMs: 0, expiresAtMs: 10_000 },
      ],
      takeoverAttempts: [
        { scope: "channel_ingest", requestingNodeId: "cluster-a", requestedAtMs: 5_000 },
      ],
    });

    const result = evaluateDualRuntimeReadiness(topology);

    expect(result.ready).toBe(false);
    expect(result.issues).toContainEqual({
      code: "takeover.leaseNotExpired",
      path: "takeoverAttempts[0]",
      message:
        'Takeover of scope "channel_ingest" by "cluster-a" was requested at 5000, before the current lease (held by "mac-mini") expires at 10000.',
    });
  });

  it("allows a takeover requested at or after lease expiry", () => {
    const topology = baseTopology({
      leases: [
        { scope: "channel_ingest", ownerNodeId: "mac-mini", acquiredAtMs: 0, expiresAtMs: 10_000 },
      ],
      takeoverAttempts: [
        { scope: "channel_ingest", requestingNodeId: "cluster-a", requestedAtMs: 10_000 },
      ],
    });

    const result = evaluateDualRuntimeReadiness(topology);

    expect(result.ready).toBe(true);
    expect(result.issues).toEqual([]);
  });

  it("orders issues by canonical scope order regardless of writer input order, and summary is stable", () => {
    const scrambledMissingChannelIngest: DualRuntimeTopology = baseTopology({
      writers: [
        writer({ scope: "shared_memory", nodeId: "cluster-a" }),
        writer({ scope: "shared_memory", nodeId: "mac-mini" }),
        writer({ scope: "session_delivery", nodeId: "cluster-a" }),
        writer({ scope: "scheduler", nodeId: "mac-mini" }),
      ],
    });

    const result = evaluateDualRuntimeReadiness(scrambledMissingChannelIngest);

    expect(result.issues.map((issue) => issue.code)).toEqual([
      "writer.missingOwner",
      "writer.multipleOwners",
    ]);
    expect(result.issues[0].path).toBe("writers[scope=channel_ingest]");
    expect(result.issues[1].path).toBe("writers[scope=shared_memory]");

    expect(result.summary.writerScopes.map((entry) => entry.scope)).toEqual([
      "channel_ingest",
      "scheduler",
      "session_delivery",
      "shared_memory",
    ]);

    const repeat = evaluateDualRuntimeReadiness(scrambledMissingChannelIngest);
    expect(repeat).toEqual(result);
  });

  it("flags empty clusterId, unknown writer scope, and unknown writer nodeId", () => {
    const topology = baseTopology({
      nodes: [macMiniNode({ clusterId: "" }), clusterNode()],
      writers: [
        writer({ scope: "channel_ingest", nodeId: "mac-mini" }),
        writer({ scope: "scheduler", nodeId: "mac-mini" }),
        writer({ scope: "session_delivery", nodeId: "cluster-a" }),
        writer({
          scope: "unknown_scope" as unknown as WriterOwnerAssignment["scope"],
          nodeId: "ghost-node",
        }),
        writer({ scope: "shared_memory", nodeId: "cluster-a" }),
      ],
    });

    const result = evaluateDualRuntimeReadiness(topology);

    expect(result.ready).toBe(false);
    expect(result.issues).toContainEqual(
      expect.objectContaining({ code: "node.emptyClusterId", path: "nodes[0].clusterId" }),
    );
    expect(result.issues).toContainEqual(
      expect.objectContaining({ code: "writer.unknownScope", path: "writers[3].scope" }),
    );
    expect(result.issues).toContainEqual(
      expect.objectContaining({ code: "writer.unknownNode", path: "writers[3].nodeId" }),
    );
  });
});
