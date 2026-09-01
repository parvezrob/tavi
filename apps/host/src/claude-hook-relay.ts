// Forwards a Claude Code hook payload from stdin to the local Tavi host.
// This exists so the pairing token never appears on a command line (issue
// #32): the relay reads it from the owner-only config file itself. It must
// stay silent on stdout (UserPromptSubmit stdout becomes model context) and
// must never fail loudly — a down host can not be allowed to stall Claude.
import { readFileSync } from "node:fs";
import { request } from "node:http";
import { homedir } from "node:os";
import path from "node:path";

const port = Number(process.argv[2]);

function readToken(): string | undefined {
  // ~/.mocha is the pre-rename state directory; the host moves it on its
  // first start, but a hook can fire before that.
  for (const directory of [".tavi", ".mocha"]) {
    try {
      const file = path.join(homedir(), directory, "config.json");
      const parsed = JSON.parse(readFileSync(file, "utf8")) as { token?: unknown };
      if (typeof parsed.token === "string" && parsed.token) return parsed.token;
    } catch {
      // Try the next location.
    }
  }
  return undefined;
}

const token = readToken();
if (!token || !Number.isInteger(port) || port <= 0) {
  process.exit(0);
}

const chunks: Buffer[] = [];
process.stdin.on("data", (chunk) => chunks.push(chunk));
process.stdin.on("error", () => process.exit(0));
process.stdin.on("end", () => {
  const body = Buffer.concat(chunks);
  const forward = request(
    {
      host: "127.0.0.1",
      port,
      path: "/api/hooks/claude",
      method: "POST",
      timeout: 3000,
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
        "Content-Length": body.length,
      },
    },
    (response) => {
      response.resume();
      response.on("end", () => process.exit(0));
      response.on("error", () => process.exit(0));
    },
  );
  forward.on("timeout", () => forward.destroy());
  forward.on("error", () => process.exit(0));
  forward.end(body);
});
