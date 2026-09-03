import { execFile } from "node:child_process";
import qrcode from "qrcode-terminal";
import type { HostConfig } from "./config.js";
import { encodePairingPayload } from "./pairing.js";

// `tavi pair`: ask the running host for a single-use code and show it as a
// QR the phone scans. It goes through the host's own API rather than the
// state files so the code lives in the process that will redeem it.

export async function resolvePublicUrl(config: HostConfig, args: string[]): Promise<string> {
  const flag = args.indexOf("--url");
  if (flag !== -1 && args[flag + 1]) return normalize(args[flag + 1] ?? "");
  if (process.env.TAVI_PUBLIC_URL) return normalize(process.env.TAVI_PUBLIC_URL);
  const tailscale = await tailscaleDnsName();
  if (tailscale) return `https://${tailscale}`;
  throw new Error(
    "Could not work out this Mac's Tailscale address. Run `tailscale serve` first, or pass --url https://<name>.ts.net.",
  );
}

export async function runPairCommand(config: HostConfig, publicUrl: string): Promise<void> {
  const response = await fetch(`http://${config.bindHost}:${config.port}/api/pair/begin`, {
    method: "POST",
    headers: { Authorization: `Bearer ${config.token}` },
  }).catch(() => undefined);
  if (!response) {
    throw new Error("The Tavi host is not running. Start it (`npm run service:install`) and try again.");
  }
  const body = (await response.json()) as {
    secret?: string;
    expiresAt?: string;
    host?: { name: string; fingerprint: string };
    error?: string;
  };
  if (!response.ok || !body.secret || !body.host) {
    throw new Error(body.error ?? `The host refused to start pairing (HTTP ${response.status}).`);
  }

  const payload = encodePairingPayload({
    url: publicUrl,
    secret: body.secret,
    fingerprint: body.host.fingerprint,
    hostName: body.host.name,
  });
  console.log(`Scan this in Tavi on your phone (tap “Scan pairing code”):\n`);
  // With a callback the library hands the drawing to it instead of printing.
  const drawing = await new Promise<string>((resolve) => qrcode.generate(payload, { small: true }, resolve));
  console.log(drawing);
  console.log(
    `The phone will show ${body.host.name} with fingerprint ${body.host.fingerprint} — check they match, then confirm.`,
  );
  console.log(`This code works once, for a few minutes.\n`);
  console.log("No camera? Type this into the app instead:");
  console.log(`  ${payload}\n`);
}

function normalize(url: string): string {
  const trimmed = url.trim().replace(/\/+$/, "");
  if (!/^https:\/\//.test(trimmed)) {
    throw new Error(`The public URL must be HTTPS (got ${trimmed}). Tavi pairs only over Tailscale Serve.`);
  }
  return trimmed;
}

function tailscaleDnsName(): Promise<string | undefined> {
  return new Promise((resolve) => {
    execFile("tailscale", ["status", "--json"], { timeout: 5_000 }, (error, stdout) => {
      if (error) return resolve(undefined);
      try {
        const status = JSON.parse(stdout) as { Self?: { DNSName?: string } };
        const name = status.Self?.DNSName?.replace(/\.$/, "");
        resolve(name || undefined);
      } catch {
        resolve(undefined);
      }
    });
  });
}
