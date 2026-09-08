import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { Command } from "commander";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { createCliRuntimeCapture } from "./test-runtime-capture.js";

const { runtimeLogs, runtimeErrors, defaultRuntime, resetRuntimeCapture } =
  createCliRuntimeCapture();

vi.mock("../runtime.js", async () => ({
  ...(await vi.importActual<typeof import("../runtime.js")>("../runtime.js")),
  defaultRuntime,
}));

const { registerRuntimeCli } = await import("./runtime-cli.js");
const { getSubCliEntries } = await import("./program/subcli-descriptors.js");

function validFencing() {
  return { backend: "redis", leaseTtlMs: 5_000, renewalIntervalMs: 1_000, takeoverGraceMs: 5_000 };
}

function readyTopology() {
  return {
    nodes: [
      { nodeId: "mac-mini", clusterId: "mac-mini-cluster", executionEnabled: true },
      { nodeId: "cluster-a", clusterId: "cluster-a-cluster", executionEnabled: true },
    ],
    writers: [
      { scope: "channel_ingest", nodeId: "mac-mini", enabled: true, fencing: validFencing() },
      { scope: "scheduler", nodeId: "mac-mini", enabled: true, fencing: validFencing() },
      { scope: "session_delivery", nodeId: "cluster-a", enabled: true, fencing: validFencing() },
      { scope: "shared_memory", nodeId: "cluster-a", enabled: true, fencing: validFencing() },
    ],
  };
}

async function withConfigFile(content: string, run: (configPath: string) => Promise<void>) {
  const configPath = path.join(
    os.tmpdir(),
    `openclaw-runtime-readiness-cli-test-${Date.now()}-${Math.random().toString(16).slice(2)}.json`,
  );
  await fs.writeFile(configPath, content, "utf8");
  try {
    await run(configPath);
  } finally {
    await fs.rm(configPath, { force: true });
  }
}

describe("runtime-cli", () => {
  async function runCli(args: string[]) {
    const program = new Command();
    registerRuntimeCli(program);
    try {
      await program.parseAsync(args, { from: "user" });
    } catch (err) {
      if (!(err instanceof Error && err.message.startsWith("__exit__:"))) {
        throw err;
      }
    }
  }

  beforeEach(() => {
    vi.clearAllMocks();
    resetRuntimeCapture();
  });

  it("registers a runtime command group with a readiness subcommand", () => {
    const program = new Command();
    const runtime = registerRuntimeCli(program);

    expect(program.commands.map((cmd) => cmd.name())).toEqual(["runtime"]);
    expect(runtime.commands.map((cmd) => cmd.name())).toEqual(["readiness"]);
  });

  it("is registered in the sub-CLI descriptor catalog", () => {
    const names = getSubCliEntries().map((descriptor) => descriptor.name);
    expect(names).toContain("runtime");
  });

  it("exits 0 and prints a ready JSON report for a valid, ready topology", async () => {
    await withConfigFile(JSON.stringify(readyTopology()), async (configPath) => {
      await runCli(["runtime", "readiness", "--config", configPath, "--json"]);

      expect(defaultRuntime.exit).not.toHaveBeenCalled();
      expect(runtimeLogs).toHaveLength(1);
      const printed = JSON.parse(runtimeLogs[0]) as { ready: boolean; issues: unknown[] };
      expect(printed.ready).toBe(true);
      expect(printed.issues).toEqual([]);
    });
  });

  it("exits 1 for a structurally valid but not-ready topology", async () => {
    const topology = readyTopology();
    topology.writers = topology.writers.filter((writer) => writer.scope !== "shared_memory");

    await withConfigFile(JSON.stringify(topology), async (configPath) => {
      await runCli(["runtime", "readiness", "--config", configPath, "--json"]);

      expect(defaultRuntime.exit).toHaveBeenCalledWith(1);
      const printed = JSON.parse(runtimeLogs[0]) as { ready: boolean; issues: { code: string }[] };
      expect(printed.ready).toBe(false);
      expect(printed.issues).toContainEqual(
        expect.objectContaining({ code: "writer.missingOwner" }),
      );
    });
  });

  it("prints a short human-readable report without --json", async () => {
    const topology = readyTopology();
    topology.writers = topology.writers.filter((writer) => writer.scope !== "shared_memory");

    await withConfigFile(JSON.stringify(topology), async (configPath) => {
      await runCli(["runtime", "readiness", "--config", configPath]);

      expect(defaultRuntime.exit).toHaveBeenCalledWith(1);
      expect(runtimeLogs[0]).toBe("Dual-runtime readiness: NOT READY (1 issue(s))");
      expect(runtimeLogs.some((line) => line.includes("writer.missingOwner"))).toBe(true);
    });
  });

  it("exits 2 for malformed JSON", async () => {
    await withConfigFile("{ not valid json", async (configPath) => {
      await runCli(["runtime", "readiness", "--config", configPath, "--json"]);

      expect(defaultRuntime.exit).toHaveBeenCalledWith(2);
      expect(defaultRuntime.writeJson).not.toHaveBeenCalled();
      expect(runtimeErrors[0]).toContain("is not valid JSON");
    });
  });

  it("exits 2 when the config does not match the expected topology shape", async () => {
    await withConfigFile(
      JSON.stringify({ nodes: [], writers: [], extra: true }),
      async (configPath) => {
        await runCli(["runtime", "readiness", "--config", configPath, "--json"]);

        expect(defaultRuntime.exit).toHaveBeenCalledWith(2);
        expect(runtimeErrors[0]).toContain(
          "does not match the expected dual-runtime topology shape",
        );
      },
    );
  });

  it("exits 2 when the config file does not exist", async () => {
    const missingPath = path.join(
      os.tmpdir(),
      `openclaw-runtime-readiness-missing-${Date.now()}.json`,
    );

    await runCli(["runtime", "readiness", "--config", missingPath, "--json"]);

    expect(defaultRuntime.exit).toHaveBeenCalledWith(2);
    expect(runtimeErrors[0]).toContain("Unable to read config file");
  });

  it("exits 2 when --config is omitted", async () => {
    await runCli(["runtime", "readiness"]);

    expect(defaultRuntime.exit).toHaveBeenCalledWith(2);
    expect(runtimeErrors[0]).toContain("--config <file> is required");
  });
});
