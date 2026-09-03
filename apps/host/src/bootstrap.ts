import path from "node:path";
import type { BootstrapDeps } from "./bootstrap-deps.js";
import { type HostConfig, VERSION } from "./config.js";
import {
  type Check,
  checkDoor,
  checkPty,
  checkServe,
  checkService,
  checkTailscale,
  describe,
  doorCommand,
  firstLine,
} from "./doctor.js";

// `tavi pair` on a fresh Mac (#47): everything a tester would otherwise do
// by hand — install the service, expose it through Tailscale Serve, notice a
// missing prerequisite — happens here. One checklist, one yes/no question,
// then a ✓ line per step. `doctor.ts` reports the same checks read-only.

const HEALTH_WAIT_MS = 15_000;

export class BootstrapError extends Error {
  constructor(public readonly checks: Check[]) {
    super(checks.map((check) => `${check.name}: ${check.detail}${check.fix ? `\n  → ${check.fix}` : ""}`).join("\n"));
  }
}

interface Step {
  /** What the plan says will happen ("Install Tailscale and sign in"). */
  label: string;
  /** The ✓ line once it has ("Tailscale connected"). */
  done: string;
  optional?: boolean;
  /** Does the work; may return a short detail for the ✓ line. */
  run: () => Promise<string | undefined>;
}

/**
 * Make the machine ready to pair: one checklist of what is already fine and
 * what will be done, one yes/no question, then each step reports a ✓ line.
 * Nothing technical reaches the screen unless a step fails, and then it is
 * one plain sentence plus the log path. Throws with `doctor`'s instructions
 * when the person says no or something still needs them.
 */
export async function bootstrap(config: HostConfig, deps: BootstrapDeps): Promise<void> {
  const pty = await checkPty(deps);
  if (!pty.ok) throw new BootstrapError([pty]);

  const tailscale = await checkTailscale(deps);
  const serve = await checkServe(config, deps, tailscale.cli);
  const door = await checkDoor(config, deps, tailscale.cli);
  const service = await checkService(config, deps);
  const herdr = await deps.which("herdr");

  const lines: string[] = ["  ✓ Terminal ready"];
  const steps: Step[] = [];
  const pending: Check[] = [];

  if (tailscale.check.ok) {
    lines.push(`  ✓ Tailscale connected  (${tailscale.check.detail.replace(/^connected as /, "")})`);
  } else {
    const label = tailscale.cli ? "Start Tailscale and sign in" : "Install Tailscale and sign in";
    lines.push(`  • ${label}  — will do`);
    pending.push(tailscale.check);
    steps.push({ label, done: "Tailscale connected", run: () => stepTailscale(deps) });
  }
  if (serve.ok) {
    lines.push(`  ✓ Private address for your phone  (${serve.detail.split(" → ")[0]})`);
  } else {
    lines.push("  • Private address for your phone  — will set up");
    pending.push(serve);
    steps.push({ label: "Private address", done: "Private address", run: () => stepServe(config, deps) });
  }
  if (door.ok) {
    lines.push("  ✓ Private address for previews  (dev servers on the phone)");
  } else {
    lines.push("  • Private address for previews, so dev servers show on the phone  — will set up");
    steps.push({
      label: "Private address for previews",
      done: "Private address for previews",
      run: () => stepDoor(config, deps),
    });
  }
  if (service.ok) {
    lines.push("  ✓ Tavi runs in the background");
  } else if (service.outdated) {
    lines.push(`  • Update Tavi in the background to ${VERSION}  — will do`);
    pending.push(service);
    steps.push({
      label: "Update Tavi in the background",
      done: `Tavi runs in the background  (${VERSION})`,
      run: () => stepService(config, deps),
    });
  } else {
    lines.push("  • Run Tavi in the background  — will set up");
    pending.push(service);
    steps.push({
      label: "Run Tavi in the background",
      done: "Tavi runs in the background",
      run: () => stepService(config, deps),
    });
  }
  const command = await deps.commandStatus();
  if (command.needed && command.ok) {
    lines.push("  ✓ `tavi` command ready");
  } else if (command.needed) {
    lines.push("  • The `tavi` command, for `tavi update` and `tavi doctor`  — will add");
    steps.push({ label: "Add the `tavi` command", done: "`tavi` command ready", run: () => deps.linkCommand() });
  }
  const herdrRunning = herdr ? await deps.herdrRunning() : false;
  if (herdr && herdrRunning) {
    lines.push("  ✓ herdr running  (agent cards)");
  } else if (herdr) {
    lines.push("  • Start herdr in the background, for the agent cards  — will set up");
    steps.push({
      label: "herdr",
      done: "herdr running",
      optional: true,
      run: async () => {
        await deps.startHerdr(herdr);
        await waitFor(deps, () => deps.herdrRunning(), "herdr did not answer");
        return undefined;
      },
    });
  } else {
    const install = installHerdrCommand(deps);
    if (install) {
      lines.push("  • Install herdr and start it, for the agent cards  — will do");
      steps.push({
        label: "herdr",
        done: "herdr running",
        optional: true,
        run: async () => {
          await deps.run(install[0] as string, install.slice(1));
          const installed = await deps.which("herdr");
          if (!installed) throw new Error("herdr was not found after the install");
          await deps.startHerdr(installed);
          await waitFor(deps, () => deps.herdrRunning(), "herdr did not answer");
          return undefined;
        },
      });
    }
  }

  deps.report(`\nTavi — setting up this computer\n\n${lines.join("\n")}\n`);
  if (steps.length === 0) return;

  const count = steps.length === 1 ? "this" : `these ${steps.length} things`;
  if (!(await deps.ask(`Do ${count} now? Your password may be asked once.`))) {
    throw new BootstrapError(pending);
  }
  deps.report("");
  for (const step of steps) {
    try {
      const detail = await step.run();
      deps.report(`  ✓ ${step.done}${detail ? `   ${detail}` : ""}`);
    } catch (error) {
      if (step.optional) {
        deps.report(`  – ${step.label} skipped: ${firstLine(describe(error))}. Tavi still works as a terminal.`);
        continue;
      }
      throw error instanceof BootstrapError
        ? error
        : new BootstrapError([{ name: step.label, ok: false, detail: firstLine(describe(error)) }]);
    }
  }
  deps.report("");
}

// Installs and/or starts Tailscale. `tailscale up` prints the sign-in link
// itself and returns once the browser side is done.
async function stepTailscale(deps: BootstrapDeps): Promise<string | undefined> {
  // Not a retry of one flaky call: each pass fixes one thing the check
  // named (install, then operator, then `up`), so the loop needs one pass
  // per fix plus the confirming re-check.
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const { check, cli } = await checkTailscale(deps);
    if (check.ok) return check.detail.replace(/^connected as /, "");
    if (!cli) {
      const install = tailscaleInstallCommand(deps);
      if (!install) throw new BootstrapError([check]);
      await deps.run(install[0] as string, install.slice(1));
      continue;
    }
    if (deps.operatingSystem === "linux") await ensureOperator(deps, cli);
    await deps.run(cli, ["up"]).catch(async () => {
      await deps.run("sudo", [cli, "up"]);
    });
  }
  throw new BootstrapError([(await checkTailscale(deps)).check]);
}

async function stepServe(config: HostConfig, deps: BootstrapDeps): Promise<string | undefined> {
  const cli = (await checkTailscale(deps)).cli;
  if (!cli) throw new Error("Tailscale is not available.");
  // One pass per fix a failed check can apply (operator, then HTTPS certs,
  // then the retried `serve`), plus the pass that confirms it took.
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const serve = await checkServe(config, deps, cli);
    if (serve.ok) return serve.detail.split(" → ")[0];
    try {
      await deps.execute(cli, ["serve", "--bg", String(config.port)]);
    } catch (error) {
      const explained = explainServeFailure(describe(error), config.port);
      if (explained.kind === "operator") {
        await ensureOperator(deps, cli, true);
        continue;
      }
      if (explained.kind === "https") {
        throw new BootstrapError([
          {
            name: "Private address",
            ok: false,
            detail: "Tailscale needs HTTPS certificates turned on for your network (one time).",
            fix: "Open https://login.tailscale.com/admin/dns, turn on “HTTPS Certificates”, then run `npx tavi-host pair` again.",
          },
        ]);
      }
      throw new BootstrapError([{ ...serve, ...explained }]);
    }
  }
  throw new BootstrapError([await checkServe(config, deps, cli)]);
}

// The preview door (#58): a second Serve entry, set once, that fronts the
// host's preview listener. Nothing gets through it without a ticket, so it
// is as safe to leave up as the host's own address.
async function stepDoor(config: HostConfig, deps: BootstrapDeps): Promise<string | undefined> {
  const cli = (await checkTailscale(deps)).cli;
  if (!cli) throw new Error("Tailscale is not available.");
  // Tailscale is already up by here, so the only fix a pass can apply is
  // the operator question: one pass to ask it, one to retry, one to confirm.
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const door = await checkDoor(config, deps, cli);
    if (door.ok) return door.detail.split(" → ")[0];
    try {
      await deps.execute(cli, ["serve", "--bg", `--https=${config.previewDoorPort}`, String(config.previewPort)]);
    } catch (error) {
      const explained = explainServeFailure(describe(error), config.previewPort);
      if (explained.kind === "operator") {
        await ensureOperator(deps, cli, true);
        continue;
      }
      throw new BootstrapError([{ ...door, detail: explained.detail, fix: doorCommand(config) }]);
    }
  }
  throw new BootstrapError([await checkDoor(config, deps, cli)]);
}

async function ensureOperator(deps: BootstrapDeps, cli: string, force = false): Promise<void> {
  const user = deps.env.USER || deps.env.LOGNAME;
  if (!user) return;
  if (!force) {
    const ok = await deps
      .execute(cli, ["serve", "status", "--json"])
      .then(() => true)
      .catch(() => false);
    if (ok) return;
  }
  await deps.run("sudo", [cli, "set", `--operator=${user}`]);
}

async function stepService(config: HostConfig, deps: BootstrapDeps): Promise<string | undefined> {
  const log = path.join(config.stateDir, "host.log");
  try {
    await deps.installService();
    await waitHealthy(config, deps, "Tavi was set up but is not answering");
    return undefined;
  } catch (error) {
    // The person still gets to pair today; the service is Tavi's problem
    // to fix and the details go to the log, not their screen.
    deps.report(
      `  – Couldn't set Tavi to run in the background here (details in ${log} — please share that file with us).`,
    );
    deps.report(`    Running Tavi for this session instead. (${firstLine(describe(error))})`);
  }
  await deps.startForSession();
  await waitHealthy(config, deps, "Tavi could not start on this computer");
  return "until you log out";
}

async function waitFor(deps: BootstrapDeps, ready: () => Promise<boolean>, problem: string): Promise<void> {
  const deadline = deps.now() + HEALTH_WAIT_MS;
  while (!(await ready())) {
    if (deps.now() >= deadline) throw new Error(`${problem} after ${HEALTH_WAIT_MS / 1000}s.`);
    await deps.sleep(250);
  }
}

async function waitHealthy(config: HostConfig, deps: BootstrapDeps, problem: string): Promise<void> {
  const deadline = deps.now() + HEALTH_WAIT_MS;
  while ((await deps.healthy(config.port)) !== VERSION) {
    if (deps.now() >= deadline) {
      throw new Error(
        `${problem} on port ${config.port} after ${HEALTH_WAIT_MS / 1000}s. See ${path.join(config.stateDir, "host.log")}.`,
      );
    }
    await deps.sleep(250);
  }
}

function tailscaleInstallCommand(deps: BootstrapDeps): string[] | undefined {
  if (deps.operatingSystem === "darwin") return ["brew", "install", "--cask", "tailscale"];
  if (deps.operatingSystem === "linux") return ["sh", "-c", "curl -fsSL https://tailscale.com/install.sh | sh"];
  return undefined;
}

function installHerdrCommand(deps: BootstrapDeps): string[] | undefined {
  if (deps.operatingSystem === "darwin") return ["brew", "install", "herdr"];
  if (deps.operatingSystem === "linux") return ["sh", "-c", "curl -fsSL https://herdr.dev/install.sh | sh"];
  return undefined;
}

// Tailscale's own error text names the real cause; pass the right one on
// rather than guessing. On Linux the CLI needs root or an operator user to
// change serve config; HTTPS certs are a one-time tailnet setting.
function explainServeFailure(
  message: string,
  port: number,
): { kind: "operator" | "https" | "other"; detail: string; fix: string } {
  const command = `tailscale serve --bg ${port}`;
  if (/Access denied|serve config denied|operator/i.test(message)) {
    return {
      kind: "operator",
      detail: "Tailscale would not let this user change its serve config (Linux needs root or an operator user).",
      fix: `Run once: sudo tailscale set --operator=$USER — then run \`tavi pair\` again (or: sudo ${command}).`,
    };
  }
  if (/HTTPS|cert|MagicDNS/i.test(message)) {
    return {
      kind: "https",
      detail: `Tailscale refused: ${firstLine(message)}`,
      fix: `Enable HTTPS certificates for your tailnet (Tailscale admin → DNS → HTTPS Certificates), then run: ${command}`,
    };
  }
  return {
    kind: "other",
    detail: `Configuring it failed: ${firstLine(message)}`,
    fix: `Run ${command} yourself and read Tailscale's message.`,
  };
}
