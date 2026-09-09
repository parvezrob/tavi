# Screens / Screens Connect (Edovia): facts (sub-agent, 2026-09-09)
- VNC/RFB over TCP (5900), optional SSH tunnel (22). No proprietary protocol, no UDP/QUIC.
- NAT: UPnP/NAT-PMP/PCP inbound port mapping + directory (Screens ID → public IP:port). No STUN/ICE/hole punching. **No relay at all** as of 2026-09; CGNAT = hard failure; Edovia's documented answer is manual port forwarding or install Tailscale (Tailscale/NordVPN Meshnet integrations = read device list via OAuth, connect to IP; tunnel belongs to the other app).
- No NetworkExtension. E2E claim in marketing; support docs say SSH "can" be used (opt-in).
- No session resumption: auto-reconnect only (5.6.1, 5.7.2, 5.8.10 "faster detection of interrupted connections").
- Complaints concentrate on "works at home, fails remotely", "port mapping failed"; Jump Desktop and TeamViewer work where Screens fails (relay/hole punch). Blog 2026-07-21 "Improving Screens Connect … reliability, compatibility, performance".
- Pricing $3.99/mo, $29.99/yr, lifetime $179.99 (was $74 at launch).
