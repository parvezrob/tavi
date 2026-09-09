# Connection research pack, 2026-09-09

Evidence base for `docs/CONNECTION_ARCHITECTURE.md` (the plan) and issue #119. Produced the day the phone's Tailscale extension stalled (`docs/history/2026-09-09-tailscale-stall/`).

Research (five parallel tracks, web + primary sources, facts only, inferences marked):

- `01-product-survey.md` — how Parsec, Jump, Screens, Moonlight, RustDesk, AnyDesk, Chrome Remote Desktop, TeamViewer, Mosh, Blink, Termius, Prompt, Tailscale SSH, Eternal Terminal, ttyd, Happy Coder, Claude Code Remote Control, Codex, Cursor, VS Code Tunnels, Omnara, and the tunnel services actually connect; twelve patterns at the end.
- `01b-screens-connect.md` — Screens by Edovia in detail (the "no relay" counterexample).
- `02-embeddable-transports.md` — iroh, libp2p, WebRTC, QUIC on iOS, MPTCP, TailscaleKit/libtailscale, boringtun, Nebula/ZeroTier/NetBird; comparison table.
- `03-relay-infra.md` — Cloudflare (Tunnel, Workers + Durable Objects, Spectrum, TURN, outages, SLA), Fly.io, other edge/anycast, managed realtime pricing, DERP, latency facts, availability math, relay share.
- `04-resumable-sessions.md` — Mosh SSP, Eternal Terminal, tmux/VS Code/Coder replay, input safety designs, iOS specifics, QUIC migration semantics; eighteen design ingredients.
- `05-ios-and-tailscale.md` — the Tailscale iOS stall bug class (issue numbers, versions), NetworkExtension limits, Network.framework facts, background execution, QUIC on iOS, cellular NAT, App Review guidelines.

Review record (`review/`, GPT-6 Astra via `.claude/skills/second-opinion`, effort xhigh, each seat cold):

- `memo-v2.md` → round 1: `r1-seat1.md` (fresh eyes), `r1-seat2.md` (networking/iOS, opened the sources), `r1-seat3.md` (security/ops). All NOT APPROVED; 41 findings.
- `memo-v3.md` → round 2: `r2-fold-audit.md`, `r2-fresh-eyes.md`. NOT LOCKABLE / NOT APPROVED; 23 findings.
- `memo-v4.md` → round 3: `r3-fold-audit.md`. NOT LOCKABLE; 12 findings, one blocker.
- v5 = `docs/CONNECTION_ARCHITECTURE.md`, folding round 3 (§7c). Not re-reviewed: the plan is for the owner's decision; each phase gets its own contract lock before implementation, Layer 1 first.
