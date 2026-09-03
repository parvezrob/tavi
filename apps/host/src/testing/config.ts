import type { HostConfig } from "../config.js";

/** The HostConfig the host's tests run against; override only the fields a test is about. */
export function testConfig(overrides: Partial<HostConfig> = {}): HostConfig {
  return {
    bindHost: "127.0.0.1",
    port: 8787,
    token: "test-token-that-is-long-enough",
    shell: "/bin/zsh",
    herdrSocket: "/tmp/tavi-test-herdr.sock",
    roots: [],
    stateDir: "/tmp",
    machineName: "test-host",
    previewPort: 8788,
    previewDoorPort: 8443,
    ...overrides,
  };
}
