# 2026-09-09 23:18 – 2026-09-10 00:42 — second episode: twelve stalls in half an hour on cellular, host fedora-1

Same day, same bug class, different host. Issue: #119. Raw files: `raw-evening/fedora-host.log` (fedora-1's whole `~/.tavi/host.log`, no timestamps; tonight is the segment after the last `Tavi 0.1.18 is running` line) and `raw-evening/fedora-tailscaled-2200-0121.log` (`journalctl -u tailscaled` on fedora-1, 22:00 → 01:21, timestamped). Pulled over Taildrop; fedora-1 refuses SSH (tailnet policy has no SSH rule, and SELinux is on).

## What the owner saw

Using fedora-1 (host 0.1.18) from the phone on mobile data, away from home. "The network disconnect was crazy, happening almost every few minutes." Each time, the owner toggled the phone's Tailscale VPN off and on, and it came back.

## What the logs show

fedora-1's Tailscale journal records the phone's disco key changing 14 times between 23:18 and 00:34. A new disco key means the phone's Tailscale extension process was started fresh, which here was the owner's toggle each time:

| time | phone network | note |
|---|---|---|
| 23:18 | home Wi-Fi (192.168.0.228) | first contact, direct |
| 23:42 | cellular (CGNAT 10.101.11.4) | one key held for 20 min: cellular alone is not the trigger |
| 00:03, 00:04, 00:07, 00:09 | cellular | four stalls in 7 min |
| 00:20, 00:21, 00:22, 00:24, 00:26, 00:27, 00:29, 00:34 | cellular | eight stalls in 14 min |
| 00:34 – 00:42 | cellular, public mapping 37.111.224.149 | stable direct for 8 min, then the owner stopped |
| 01:11 | home Wi-Fi | phone came home; fine since |

Each stall has the same shape in the journal:

1. Phone and fedora exchanging disco pings direct, endpoint stable.
2. fedora loses the direct path and starts sending via derp-6 every 3–5 s (`new contact … via=derp`), getting nothing back, for 30–60 s. This is the stall: the phone's extension is alive but not reading.
3. `derp-6 does not know about peer [8lRaA], removing route`: the phone's extension has dropped off its home relay (the owner switched the VPN off).
4. New disco key, new endpoint port, `via=direct` within 2–3 s (VPN back on).
5. One to three minutes of working terminal, then step 2 again.

fedora-1's own side was healthy throughout: no `LinkChange`, no rebind, its derp-6 connection ten hours old, direct path to the phone re-established within seconds of every restart.

The host log (tonight's segment) agrees: 36 terminal sockets closed `1006 abnormal`, terminal lifetimes mostly 80–130 s, five `heartbeat terminate: two unanswered pings` events-socket kills at 45 s, and the app redialling within seconds each time. Host and app both behaved correctly; the pipe under them died every two minutes.

## Reading

- Same class as the morning (tailscale#19504 / #18889 / #15271: the iOS extension's receive loop dies on a socket rebind and nothing restarts it), triggered far more often on mobile data in motion (carrier NAT remaps, tower handovers), with an interactive terminal making every stall visible within seconds.
- The 20 quiet minutes at 23:42–00:03 on the same carrier say the trigger is a network transition, not cellular as such. The storm from 00:03 likely coincides with the owner moving.
- The app has exactly one route, through that extension. Nothing in Tavi could have recovered this; only the toggle did, twelve times. This is the case `docs/CONNECTION_ARCHITECTURE.md` is written for.
- Not the Mac: the Mac was closed-lid asleep on battery from 22:42 to 01:06 (pmset log), which was a red herring in this session's first reading before the owner said the host was fedora-1.

## Still unknown

- The phone's own view (`IPNExtension` lines, `com.apple.network` for Tavi) was not collected: the phone was not on a cable and `log collect --device` needs a real terminal. The fedora journal is sufficient to establish the pattern; the phone log would only add the exact rebind reason per stall.
- Tailscale iOS version on the phone (open since the morning).
