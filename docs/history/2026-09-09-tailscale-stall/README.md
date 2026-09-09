# 2026-09-09 07:00–07:07 — the phone's Tailscale extension stalled; Tavi had no other route

Issue: #119. Cross-referenced on #111. Files here: `evidence.md` (the raw pack handed to the cold reviewer: host log tail, both Tailscale logs, the phone's Apple network-layer lines, Wi-Fi telemetry, LAN pings) and `astra-verdict.md` (GPT-6 Astra's cold review, `second-opinion` skill, effort xhigh).

## What the owner saw

Working in a terminal on the MacBook Air from the phone (host 0.1.18, phone on `main` cda1b41). 07:03 home showed "MacBook Air · Reconnecting", the terminal screen went blank at "Connecting". 07:04 home showed "MacBook Air · Offline — isn't answering, showing the last known state". Force-quit 07:04:24, relaunch 07:04:32: connected for ~30 s, failed again. Force-quit 07:06:26. Wi-Fi and cellular both tried, same result. **07:47: turning Tailscale off and on in the phone's VPN settings fixed it instantly**, app and Mac untouched.

## Root cause

**Tailscale's iOS network extension on the phone stopped passing traffic, intermittently, for about four minutes.** Established by: the same failure on LTE and on Wi-Fi (rules out the radio); the phone-side VPN toggle fixing it with nothing else changed (rules out the Mac, the host, and the app); the phone's own Tailscale log reporting `udp=false` at 07:03:03, 07:03:27 and 07:05:25 with a direct path only between 07:04:32 and 07:05:25; the Mac's tailscaled hearing the phone only through DERP the whole window. Why the DERP relay did not carry the app's TCP even though both ends were connected to derp-3 is **not** explained by the logs; Astra says the same.

The host behaved correctly: its new heartbeat closed the events socket after two unanswered pings (45 s), twice, which is exactly what a phone that cannot answer looks like. The app also dialed correctly (every attempt is in the phone's network log, each timing out at its 10 s budget); it had nowhere else to dial.

## Things that were NOT the cause (recorded so nobody chases them again)

- **fedora-1** was off the tailnet from ~06:30 (still offline at 07:20). It explains the phone's timeouts to 100.67.205.123 and up to 16 dials/min of noise, nothing else. (192.168.0.230 in the Mac's Tailscale log is fedora, not the phone.)
- **The Xcode/CoreDevice wireless-debug tunnel** was busy on the Mac from 06:20 (`xcrun` 06:18:26, `xcodebuild` 06:20:26, then 2–4k daemon log lines per 10 min). Strong correlation with the phone's Wi-Fi losing its route at 06:23; not shown to cause the tunnel stall, and the stall recurred on LTE. Still: nothing should run xcodebuild on the Mac while the owner tests.
- **Mac load** (avg ~7 from `communicationtrustd`, Virtualization XPC, `calaccessd`; host at 0.7 %) and the **chaos soak host** still running on :8797 — noise. Kill the chaos host before the owner tests.
- **LAN packet loss** Mac→phone of 20–33 % measured at 07:07 with the router at 0 %: real, but measured after the fact and irrelevant to the LTE failure.
- **The app's foreground cycling**: the host-log pattern of events `1001 going-away` + terminal `1006` pairs is the app cancelling both sockets on every return to the foreground and redialing within 400 ms (26 background/foreground transitions in the hour). Works; costs a redial each time; not the outage.

## How the evidence was read (so the next person is faster)

- **Host log has no timestamps.** `~/.tavi/host.log` lines are in order only. Fix noted on #119 and #111 P3.
- **The phone's own reason codes were absent** from `sudo log collect --device --last 90m`: every `Logger` call in the app is `.info`, which iOS keeps in memory only. Zero `com.farfield.tavi` lines in the archive. (The 2026-09-09 small-hours handoff says device logs did show the subsystem then — possibly collected while Xcode had the app attached. Verify before relying on either claim.) What *was* available and decisive: `com.apple.network:connection` lines for process Tavi (dials, timeouts, `Receive failed "Software caused connection abort"` = the app's own cancel, endpoint hashes per process: pid 45553 Mac = `IPv4#325a8ad7`, fedora = `IPv4#c111b846`; pid 46125 Mac = `35021df8`, fedora = `d32adb76`), `IPNExtension` (Tailscale) lines, `wifid` `InfraUptime`/RSSI, `runningboardd` exit status (`user-quit` = force-quit), UIKit `Deactivation reason added/removed: 12` = background/foreground.
- **Cable rules held**: `devicectl` said `localNetwork` until the second cable; `pkill -f remotepairingd; pkill -f CoreDeviceService` after; launchd respawns them, so check `ps` before the owner tests.
- `sudo log collect` needs a real terminal (the `!` prefix has no TTY for the password).
- The Mac's `/opt/homebrew/var/log/tailscaled.log` is the only timestamped host-side source; node `8lRaA` = phone, `eHDrr` = fedora-1; on the phone `HDQrg` = Mac.

## Product conclusions (discussed with the owner, morning of 09-09; to continue in the evening)

1. **Tavi is a remote-control app.** LAN-direct fallback is the wrong fix (the Mac is never ten feet away when the app is in use). Dropped.
2. **The app needs a route that does not depend on Tailscale on the phone: a relay both ends dial out to over HTTPS.** Options, cheapest first: Cloudflare Tunnel (`cloudflared` beside the host, per-host hostname, free, zero code); own relay on Cloudflare Workers + Durable Objects (DO created by the host so it lands near the Mac, hibernating WebSockets, 1 MB/message cap is fine); own relay program on Fly.io/Hetzner in 3–4 regions with the host registering with the lowest-latency one. Swapping Tailscale for WireGuard/ZeroTier/Nebula does not help (same UDP, same failure mode).
3. **Latency/distribution**: one VPS in Singapore is ~400 ms per keystroke for a US customer. Answer: edge network (Cloudflare) or a few regions with host-side nearest-relay selection (what DERP does); local echo for typed keys (Mosh-style) hides the rest.
4. **Cost is not the issue.** Worst case 10,000 users, 20 % active 2 h/day, relay carrying everything: ~1.3 TB/month; Workers+DO ≈ $100–300/month; VPS boxes ≈ $40–200/month; Cloudflare Tunnel free (paid plan ~$200 for SLA). The real cost at that scale is the account/pairing service, monitoring, on-call, support.
5. **Primary vs fallback — open, leaning primary.** Written on #119 as fallback (race both routes, keep the first to deliver a snapshot). Argument for relay-primary: customers never install Tailscale; one path to test; edge latency 20–60 ms is fine for a terminal. Tailscale becomes the optional "direct connection" setting. Owner to decide.
6. **Resumable sessions** (host keeps terminal state + frame sequence; phone resumes from frame N on any route) turn every drop into a sub-second stutter. Third package on #119.
7. **Until the relay exists, tell the truth**: probe a public endpoint beside the host probe; internet up + host dead through the tunnel ⇒ "Tailscale on this phone has stalled" + Open Tailscale. Customers will not toggle a VPN, but it beats five force-quits and blaming the Mac. Terminal keeps its last frame unconditionally (it did at 07:47, it did not at 07:03 — find out why).

## Open questions

- Why DERP did not carry the app's TCP during the stall (both ends connected to derp-3).
- Whether `.info` app logs ever reach `log collect` (see above); either way, raise recovery logs to `.notice`.
- Why the terminal blanked at 07:03 but kept its frame at 07:47.
- Tailscale iOS version on the phone; whether this stall class is known/fixed upstream.

## Process notes

Three wrong answers preceded the right one in this session (blamed fedora-1, then the Wi-Fi/Xcode tunnel, then said force-quit fixed it). The rule that would have avoided it: **before naming a cause, split what is measured from what is inferred, and say which is which.** The cold second opinion (Astra) got the ranking right on the same evidence; the owner's VPN toggle proved it.
