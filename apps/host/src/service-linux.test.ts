import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test, { type TestContext } from "node:test";
import type { HostConfig } from "./config.js";
import { installService, uninstallService } from "./service.js";

test("Linux installs a systemd user unit with the host environment and enables linger", async (context) => {
  const home = mkdtempSync(path.join(tmpdir(), "tavi-systemd-"));
  context.after(() => rmSync(home, { recursive: true, force: true }));
  const commands: string[] = [];
  const config: HostConfig = {
    bindHost: "127.0.0.1", port: 8787, token: "token-long-enough-for-the-test-suite", shell: "/bin/bash",
    herdrSocket: path.join(home, ".config/herdr/herdr.sock"), roots: [path.join(home, "code")],
    stateDir: path.join(home, ".tavi"), machineName: "fedora", previewPort: 8788, previewDoorPort: 8443,
  };

  const unit = await installService(config, {
    operatingSystem: "linux",
    homeDirectory: home,
    packageRoot: "/opt/tavi",
    execute: async (command, args) => {
      commands.push([command, ...args].join(" "));
      if (command === "loginctl") throw new Error("polkit denied");
    },
  });

  assert.equal(unit, path.join(home, ".config/systemd/user/tavi-host.service"));
  const contents = readFileSync(unit, "utf8");
  assert.match(contents, /ExecStart=".*" "\/opt\/tavi\/dist\/index\.js"/);
  assert.match(contents, /^WorkingDirectory=\/opt\/tavi$/m);
  assert.match(contents, /Environment="TAVI_STATE_DIR=.*\.tavi"/);
  assert.match(contents, /Environment="LANG=.*UTF-8"/i);
  assert.doesNotMatch(contents, /TAVI_TOKEN/);
  assert.match(contents, /WantedBy=default\.target/);
  assert.deepEqual(commands, [
    "systemctl --user daemon-reload",
    "systemctl --user enable tavi-host.service",
    "systemctl --user restart tavi-host.service",
    "loginctl enable-linger",
  ]);

  const removed = await uninstallService({ operatingSystem: "linux", homeDirectory: home, execute: async () => {} });
  assert.deepEqual(removed, [unit]);
  assert.equal(existsSync(unit), false);
});
