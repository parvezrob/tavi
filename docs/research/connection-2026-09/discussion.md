# Discussion notes — the owner's questions and the answers given (2026-09-09, evening)

Verbatim-in-substance record of the conversation around the plan, so nothing said in chat is lost. The plan itself is `docs/CONNECTION_ARCHITECTURE.md`; the paper is `paper.html`.

## The brief, in the owner's words

"Before we commit to anything, be it cloudflare or whatever, i want you to do a thorough investigation and research, and discuss it with astra (if needed discuss multiple rounds) and then offer me the best in class solution. I want to achieve best in class app that has 99.99% stability specially with the network. People can use it from their phone and chill their life. Wifi stability is not a solution. Think about the case where popularly people are using rented VPS today to run their agents. So, the latency, network stability is something we either fix or we just scrap the project. I want A+ connection or nothing at all!"

Also earlier the same day: "this is a remote control app. you use the app when you are away from your pc." (LAN-direct fallback rejected.) "you think a customer would care to turn tailscale on and off?" (VPN toggle is a diagnostic, never a product step.)

## Q: Why do the connection issues pop up all of a sudden, and then keep happening?

Because of how the bug works: a trap that snaps shut once. Tailscale on the phone has one loop that reads incoming packets. When the phone changes networks, Tailscale swaps its socket; there is a window where the old socket is closed and the new one is not installed. A read that lands in that window fails with "not connected", the WireGuard layer treats it as fatal and kills the reading loop, and nothing restarts it. The extension stays alive and the admin console shows "connected", but no packets are read. The trigger is a network transition, not time: the phone dropped Wi-Fi at 06:23 and came back at 07:03, and one of those swaps hit the window. It keeps failing afterwards because the dead loop stays dead; force-quitting Tavi changes nothing (the broken part is in Tailscale's process); only toggling the VPN recreates the loop. Tracked as tailscale#19504 (opened April 2026, still open), #18889, #15271; the reporters run SSH, tmux and mosh from phones.

## Q: How do most people run their whole operations on Tailscale, but our little app it can't handle?

It is not Tailscale in general, it is the iPhone client under Tavi's traffic pattern. Most Tailscale use is server-to-server or laptop-to-server, where the client is a normal daemon that does not switch networks. The iPhone client is forced by Apple to run as a VPN extension with a hard 50 MB memory cap and its own sleep/wake rules, and the phone changes networks constantly, which is the trigger. A long-lived interactive terminal with a heartbeat every few seconds makes the dead loop visible in seconds, whereas someone fetching a web page once an hour barely notices. The people who do run operations from phones keep a second path: every iOS terminal app treats Tailscale as one option beside SSH or mosh direct, and every remote-desktop app with a good reputation has its own relay. Even Tailscale's own remote-access product for iOS, Funnel, has an open bug this month where it dies silently while reporting healthy.

## Q: So an Android would never have this issue?

Not this exact bug (all the open issues are iOS-tagged; the trigger involves the iOS extension's memory cap and socket rebind), but Android has its own list: battery optimisation killing the VPN service, Doze mode, permission changes; different mechanism, same symptom. The structural problem is identical on both: Tavi is a passenger inside someone else's VPN process, unable to see it fail or restart it. Tavi is iOS-only for now, so customers are on the platform where this bug lives, and the fix is the same one we would want on Android.

## Q: If we keep Cloudflare as a fallback, will the problem be resolved forever?

Yes for this failure class, no for "forever" in general. A route that does not go through the phone's VPN makes this bug and every future Tailscale iOS bug irrelevant. Three conditions for it to hold: the fallback must be exercised on every connect, not parked (parked routes rot); the switch must be invisible (the session layer); and not Cloudflare Tunnel specifically (its default transport drops the WebSocket upgrade header, cloudflared#1652, and WebSockets are cut on Cloudflare deploys), rather our own tiny relay on Cloudflare's edge plus the same relay on a VPS as the second provider. What no route fixes: the phone has no internet at all; the Mac is asleep or shut down (a VPS avoids this); both providers down at once (the residual in the 99.99 % math); bugs in our own reconnect code (what the chaos harness is for).

## Q (from a colleague): Why do we need a relay server? What if it's just an SSH port opened on the server and we connect with the real IP?

Right for one of the two cases, and the plan has it: the `direct` route (option D). A VPS has a real public IP; the host gets its own key and TLS listener and the phone connects straight to it, pinned, no relay. Not SSH because the app speaks HTTP and WebSockets, but the same shape. Where it does not work: a computer at home. No public IP behind the home router's NAT, and in Bangladesh and much of the world behind the carrier's NAT too, where there is no port to open at all; that is yesterday's case and the case Screens by Edovia has been failing at for fifteen years ("works at home, never connects remotely"). The only ways through are a VPN (Tailscale, which broke), hole punching, or a relay both ends dial out to. Opening a port at home: carrier NAT gives no inbound path; UPnP port mapping has the worst reliability record in the survey and means telling customers to configure routers; an open shell port on a home machine is what every security guide says not to do. So: the relay is for the Mac, not the VPS; it is dumb, cannot read traffic, and is one of several routes; a VPS phone dials the real IP first. Even if every customer were on a VPS, the relay stays as the fallback against a single provider's outage.

**In plain words for the colleague:** "You're right, and we're doing exactly that for servers. When the host is a VPS with a real IP, the phone connects straight to it, no relay. That's the fastest route in the plan. The relay is for the other half of our users, the ones running agents on a laptop at home. A laptop behind a home router has no public IP, and most home and mobile connections here are behind the ISP's NAT too, so there's no port you can open. Nothing can dial in. The only options are a VPN like Tailscale, which is what broke yesterday, or a small relay that both the phone and the laptop dial out to. The relay can't read anything. It just passes encrypted bytes between two connections. Think of it as a meeting point, not a middleman. And it's a fallback for servers too, so if a provider goes down the app still has a way in."

## Q: Relay as fallback or as primary? (morning discussion, before the research)

Recommendation given: relay-primary, Tailscale optional, because customers will not install a VPN, one path is easier to test, and edge latency is fine for a terminal. The research reframed this: the routes are dialled in parallel and the first to establish wins, one alternate stays warm; for a VPS the direct route wins naturally, for a Mac the relay is the only route unless Tailscale is present. "Primary vs fallback" stops being a switch and becomes a race.

## Q: How do we handle distribution? A VPS in Singapore would kill latency for the US/EU

Geography is the floor: East US ↔ Southeast Asia is ~225 ms round trip, West Europe ↔ Southeast Asia ~170 ms, and no design removes it. What a design controls is the extra hop: an edge network (Cloudflare, 348 cities, most people within 20 ms) or a few VPS regions with the host registering on the nearest. Local echo hides keystroke latency (Mosh: 503 ms → 5 ms median on 3G). The relay is placed near the host (Durable Object created by the host's registration); the phone reaches the nearest edge and rides the backbone.

## Q: Cost at 10,000 users?

Bandwidth is not the cost. Workers + Durable Objects ≈ $39/month at the modelled workload if hibernation holds (≈ $700 if not); VPS relays $30–100 compute plus region-dependent egress ($50–2,300; India and Africa are 6× the US rate on Fly). Managed realtime services would be $550–9,000/month. The real cost is a person on call, monitoring, and support.

## Q (2026-09-10, 01:11): I was on the phone for a while, the disconnect was happening every few minutes. Check the log or are we good?

Checked. First reading blamed the Mac (closed-lid asleep on battery 22:42–01:06); wrong host, the owner was on fedora-1. fedora-1's Tailscale journal (pulled by Taildrop) shows the phone's Tailscale extension restarting 14 times between 23:18 and 00:34, twelve of them in the half hour from 00:03, each preceded by 30–60 s of fedora pushing through the relay and hearing nothing. The owner confirmed each restart was a VPN toggle to recover. fedora-1's own side was healthy throughout; the host and the app behaved correctly and redialled within seconds every time. Same bug class as the morning, faster trigger on mobile data in motion; 20 quiet minutes on the same carrier show the trigger is a transition, not cellular as such. Written up in `docs/history/2026-09-09-tailscale-stall/episode-2-evening.md`. This is the plan's case: one route, inside someone else's process, nothing in Tavi can restart it.

## What the owner said they will do

"I will read the whole architectural plan when research and review is finished." Then: "I will continue on this later. This is a big read and a big decision." The five decisions are in the plan's §8 and the paper's section 15; nothing starts before they are made except phase 0.
