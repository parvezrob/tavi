# Evidence pack — Tavi phone↔Mac outage 2026-09-09 ~07:00–07:07 (+06). All times local +06.

## Topology
- Phone iPhone 12 Pro (tailscale 100.102.71.0, LAN 192.168.0.228), app Tavi 0.1.18 build on main cda1b41.
- Mac (host, tailscale 100.70.236.37, LAN 192.168.0.226) runs tavi-host 0.1.18 on 127.0.0.1:8787 behind 'tailscale serve' https :443. Also a chaos host on :8797 (idle).
- fedora-1 (100.67.205.123, LAN 192.168.0.230) is a second paired host; offline on the tailnet since ~06:30.
- Phone reaches the host ONLY via https://<mac>.ts.net:443 (Tailscale). Two websockets: events (tavi.events.v1) and terminal (tavi.v2). Events link: dial budget 10 s, retry 2→10 s; terminal: 12 s ready deadline. App uses NWConnection/URLSession over utun4.

## Owner's experience (screenshots 07:03 and 07:04)
07:03 home: 'MacBook Air · Reconnecting'; terminal screen blank with 'Connecting'. 07:04 home: 'MacBook Air · Offline — isn't answering, showing last known state'. fedora shown Offline. Owner force-quit at 07:04:24, relaunched 07:04:32, worked ~30 s, failed again, force-quit 07:06:26. Owner says they tried both Wi-Fi and cellular; same result.

## Mac host log (no timestamps; last lines, in order)
tavi info socket: socket opened kind="terminal" device="ceab2753de82" protocol="tavi.v2"
tavi info socket: sockets open events=1 terminals=1
tavi info socket: socket closed kind="events" device="ceab2753de82" code=1001 reason="going-away" openMs=23552 byHost=false
tavi info socket: socket closed kind="terminal" device="ceab2753de82" code=1000 reason="normal" openMs=23382 byHost=false
tavi info socket: sockets open events=0 terminals=0
tavi info socket: socket opened kind="events" device="ceab2753de82" protocol="tavi.events.v1"
tavi info socket: socket opened kind="terminal" device="ceab2753de82" protocol="tavi.v2"
tavi info socket: sockets open events=1 terminals=1
tavi warn socket: heartbeat terminate: two unanswered pings kind="events" device="ceab2753de82" sinceLastPongMs=45000
tavi info socket: socket closed kind="events" device="ceab2753de82" code=1006 reason="abnormal" openMs=165006 byHost=true
tavi info socket: sockets open events=0 terminals=1
tavi info socket: socket closed kind="terminal" device="ceab2753de82" code=1006 reason="abnormal" openMs=230901 byHost=false
tavi info socket: socket opened kind="events" device="ceab2753de82" protocol="tavi.events.v1"
tavi info socket: socket opened kind="terminal" device="ceab2753de82" protocol="tavi.v2"
tavi info socket: socket closed kind="terminal" device="ceab2753de82" code=1000 reason="normal" openMs=3970 byHost=false
tavi info socket: socket opened kind="terminal" device="ceab2753de82" protocol="tavi.v2"
tavi info socket: sockets open events=1 terminals=1
tavi warn socket: heartbeat terminate: two unanswered pings kind="events" device="ceab2753de82" sinceLastPongMs=45000
tavi info socket: socket closed kind="events" device="ceab2753de82" code=1006 reason="abnormal" openMs=75004 byHost=true
tavi info socket: sockets open events=0 terminals=1
tavi info socket: socket closed kind="terminal" device="ceab2753de82" code=1000 reason="normal" openMs=144526 byHost=false
tavi info socket: sockets open events=0 terminals=0

## Mac tailscaled.log 07:00–07:07
2026/09/09 07:00:40 magicsock: lazyEndpoint.FromPeer([8lRaA]) setting epAddr(37.111.224.149:12616) in peerMap for node(100.102.71.0)
2026/09/09 07:00:40 magicsock: lazyEndpoint.FromPeer([8lRaA]) setting epAddr(37.111.224.149:12616) in peerMap for node(100.102.71.0)
2026/09/09 07:00:40 magicsock: lazyEndpoint.FromPeer([8lRaA]) setting epAddr(37.111.224.149:12616) in peerMap for node(100.102.71.0)
2026/09/09 07:00:40 portmapper: saw UPnP type WANIPConnection1 at http://192.168.0.1:1900/igd.xml; Archer C6 AC1200 MU-MIMO Wi-Fi Router (TP-Link), method=single
2026/09/09 07:00:41 magicsock: disco: node [8lRaA] d:4e3609d773bb3551 now using 37.111.224.149:12616 mtu=1360 tx=05df66b975e9
2026/09/09 07:00:41 magicsock: new contact: peer=[8lRaA] usec=603850528956 cached=false via=direct
2026/09/09 07:00:41 netcheck: DetectCaptivePortal(found=false)
2026/09/09 07:03:01 magicsock: new contact: peer=[8lRaA] usec=603991086216 cached=false via=derp
2026/09/09 07:03:07 magicsock: new contact: peer=[8lRaA] usec=603997083409 cached=false via=derp
2026/09/09 07:03:13 magicsock: new contact: peer=[8lRaA] usec=604003092387 cached=false via=derp
2026/09/09 07:03:19 magicsock: new contact: peer=[8lRaA] usec=604009053631 cached=false via=derp
2026/09/09 07:03:20 magicsock: new contact: peer=[8lRaA] usec=604009757035 cached=false via=derp
2026/09/09 07:03:25 magicsock: new contact: peer=[8lRaA] usec=604014849375 cached=false via=derp
2026/09/09 07:03:30 magicsock: new contact: peer=[8lRaA] usec=604019967636 cached=false via=derp
2026/09/09 07:03:35 magicsock: new contact: peer=[8lRaA] usec=604025051191 cached=false via=derp
2026/09/09 07:03:40 magicsock: new contact: peer=[8lRaA] usec=604030140746 cached=false via=derp
2026/09/09 07:03:45 magicsock: new contact: peer=[8lRaA] usec=604035239570 cached=false via=derp
2026/09/09 07:03:50 magicsock: new contact: peer=[8lRaA] usec=604040482046 cached=false via=derp
2026/09/09 07:03:56 magicsock: new contact: peer=[8lRaA] usec=604045750609 cached=false via=derp
2026/09/09 07:04:01 magicsock: new contact: peer=[8lRaA] usec=604050815173 cached=false via=derp
2026/09/09 07:04:06 magicsock: new contact: peer=[8lRaA] usec=604056091834 cached=false via=derp
2026/09/09 07:04:11 magicsock: new contact: peer=[8lRaA] usec=604061307248 cached=false via=derp
2026/09/09 07:04:16 magicsock: new contact: peer=[8lRaA] usec=604066369992 cached=false via=derp
2026/09/09 07:04:22 magicsock: new contact: peer=[8lRaA] usec=604071613085 cached=false via=derp
2026/09/09 07:04:31 magicsock: new contact: peer=[8lRaA] usec=604080578711 cached=false via=derp
2026/09/09 07:04:32 magicsock: disco: node [8lRaA] d:4e3609d773bb3551 now using 192.168.0.228:41641 mtu=1360 tx=0f4eda110732
2026/09/09 07:04:32 magicsock: new contact: peer=[8lRaA] usec=604081628799 cached=false via=direct
2026/09/09 07:04:32 http: proxy error: context canceled
2026/09/09 07:04:32 http: proxy error: context canceled
2026/09/09 07:04:32 http: proxy error: context canceled
2026/09/09 07:04:32 CreateEndpoint error for 100.102.71.0:60672 -> 100.70.236.37:443: connection was refused
2026/09/09 07:04:32 CreateEndpoint error for 100.102.71.0:60665 -> 100.70.236.37:443: connection was refused
2026/09/09 07:04:32 CreateEndpoint error for 100.102.71.0:60674 -> 100.70.236.37:443: connection was refused
2026/09/09 07:04:32 CreateEndpoint error for 100.102.71.0:60668 -> 100.70.236.37:443: connection was refused
2026/09/09 07:04:32 CreateEndpoint error for 100.102.71.0:60673 -> 100.70.236.37:443: connection was refused
2026/09/09 07:04:32 magicsock: disco: node [8lRaA] d:4e3609d773bb3551 now using 103.234.119.200:41641 mtu=1360 tx=c3624f1af0d7
2026/09/09 07:04:32 magicsock: disco: node [8lRaA] d:4e3609d773bb3551 now using 192.168.0.228:41641 mtu=1360 tx=bd54603e3b27
2026/09/09 07:05:07 http: proxy error: context canceled
2026/09/09 07:05:28 magicsock: new contact: peer=[8lRaA] usec=604138084066 cached=false via=derp
2026/09/09 07:05:34 magicsock: new contact: peer=[8lRaA] usec=604143968820 cached=false via=derp
2026/09/09 07:05:39 magicsock: new contact: peer=[8lRaA] usec=604149290697 cached=false via=derp
2026/09/09 07:05:44 magicsock: new contact: peer=[8lRaA] usec=604154415441 cached=false via=derp
2026/09/09 07:05:48 portmapper: saw UPnP type WANIPConnection1 at http://192.168.0.1:1900/igd.xml; Archer C6 AC1200 MU-MIMO Wi-Fi Router (TP-Link), method=single
2026/09/09 07:05:49 netcheck: DetectCaptivePortal(found=false)
2026/09/09 07:05:50 magicsock: new contact: peer=[8lRaA] usec=604159605898 cached=false via=derp
2026/09/09 07:05:55 magicsock: new contact: peer=[8lRaA] usec=604164727335 cached=false via=derp
2026/09/09 07:06:00 magicsock: new contact: peer=[8lRaA] usec=604169889024 cached=false via=derp
2026/09/09 07:06:05 magicsock: new contact: peer=[8lRaA] usec=604175036596 cached=false via=derp
2026/09/09 07:06:10 magicsock: new contact: peer=[8lRaA] usec=604180065930 cached=false via=derp
2026/09/09 07:06:16 magicsock: new contact: peer=[8lRaA] usec=604186179909 cached=false via=derp
2026/09/09 07:06:21 magicsock: new contact: peer=[8lRaA] usec=604191203079 cached=false via=derp
2026/09/09 07:06:26 magicsock: new contact: peer=[8lRaA] usec=604196233589 cached=false via=derp
2026/09/09 07:06:36 magicsock: new contact: peer=[8lRaA] usec=604206057198 cached=false via=derp
2026/09/09 07:06:47 magicsock: new contact: peer=[8lRaA] usec=604216731107 cached=false via=derp
2026/09/09 07:06:56 magicsock: new contact: peer=[8lRaA] usec=604226323345 cached=false via=derp
2026/09/09 07:07:12 magicsock: new contact: peer=[8lRaA] usec=604242362457 cached=false via=derp
2026/09/09 07:07:20 magicsock: new contact: peer=[8lRaA] usec=604249849144 cached=false via=derp
2026/09/09 07:07:27 magicsock: new contact: peer=[8lRaA] usec=604256973528 cached=false via=derp
2026/09/09 07:07:27 magicsock: disco: node [8lRaA] d:4e3609d773bb3551 now using 103.234.119.200:41641 mtu=1360 tx=3ae802ac9971
2026/09/09 07:07:27 magicsock: new contact: peer=[8lRaA] usec=604257455900 cached=false via=direct
2026/09/09 07:07:27 magicsock: disco: node [8lRaA] d:4e3609d773bb3551 now using 192.168.0.228:41641 mtu=1360 tx=859b158bdda2
2026/09/09 07:07:27 http: proxy error: context canceled
2026/09/09 07:07:27 http: proxy error: context canceled
2026/09/09 07:07:27 http: proxy error: context canceled
2026/09/09 07:07:27 CreateEndpoint error for 100.102.71.0:60720 -> 100.70.236.37:443: connection was refused
2026/09/09 07:07:27 CreateEndpoint error for 100.102.71.0:60722 -> 100.70.236.37:443: connection was refused
2026/09/09 07:07:27 CreateEndpoint error for 100.102.71.0:60725 -> 100.70.236.37:443: connection was refused
2026/09/09 07:07:27 CreateEndpoint error for 100.102.71.0:59887 -> 100.70.236.37:443: connection was refused
2026/09/09 07:07:27 CreateEndpoint error for 100.102.71.0:60727 -> 100.70.236.37:443: connection was refused

## Mac tailscaled: phone endpoint selection today (time, endpoint) — 37.111.x/103.234.x are cellular/public, 192.168.0.228 LAN
00:25 192.168.0.228
01:26 103.234.119.200
01:27 192.168.0.228
01:34 37.111.227.46
02:08 37.111.230.201
04:03 192.168.0.228
04:09 103.234.119.200
04:09 192.168.0.228
05:37 103.234.119.200
05:37 192.168.0.228
05:47 103.234.119.200
05:47 192.168.0.228
06:05 103.234.119.200
06:05 192.168.0.228
06:23 37.111.224.149
07:04 192.168.0.228
07:04 103.234.119.200
07:04 192.168.0.228
07:07 103.234.119.200
07:07 192.168.0.228

## Mac measurements at 07:07–07:08
tailscale status: iphone 'active; relay sin'. tailscale ping phone: 132ms, 33ms, 36ms, then 'no reply' (via 192.168.0.228:41641). ping 192.168.0.228 x10: 20% loss, rtt 4/60/305 ms; earlier x3: 33% loss. ping router 192.168.0.1 x10: 0% loss 3.8 ms. Mac Wi-Fi: ch157 5GHz 80MHz, -44 dBm, 866 Mbps. Mac load avg 3.6/7.1/6.6; top CPU communicationtrustd 50%, Virtualization XPC 39%, calaccessd 32%, herdr 28%; tavi host 0.7%.

## Mac: Xcode/CoreDevice wireless-debug daemons (unified log line counts per 10 min). xcrun ran 06:18:26, xcodebuild 06:20:26. Claude did not touch devicectl until 07:09.
06:0x 200 · 06:1x 50 · 06:2x 2300 · 06:3x 3800 · 06:4x 3600 · 06:5x 3500 · 07:0x 1600

## Phone unified log (log collect --device), process Tavi, Apple network layer. Endpoint hashes: in pid 45553, IPv4#325a8ad7 = Mac, IPv4#c111b846 = fedora; in pid 46125 (relaunch), IPv4#35021df8 = Mac, IPv4#d32adb76 = fedora.
### Dials to the Mac 07:02:30–07:04:20 (pid 45553)
07:03:00 C193.1.1  start_connect
07:03:10 C193.1.1  timed out
07:03:12 C196.1.1  start_connect
07:03:19 C196.2.1  start_connect
07:03:20 C199.1.1  start_connect
07:03:20 C200.1.1.1  start_connect
07:03:24 C201.1.1  start_connect
07:03:28 C199.1.1  timed out
07:03:28 C203.1.1.1  start_connect
07:03:31 C204.1.1.1  start_connect
07:03:34 C201.1.1  timed out
07:03:37 C206.1.1.1  start_connect
07:03:37 C207.1.1  start_connect
07:03:38 C209.1.1  start_connect
07:03:43 C210.1.1.1  start_connect
07:03:44 C211.1.1  start_connect
07:03:46 C209.1.1  timed out
07:03:50 C214.1.1.1  start_connect
07:03:54 C211.1.1  timed out
07:03:57 C216.1.1.1  start_connect
07:04:01 C217.1.1  start_connect
07:04:01 C218.1.1  start_connect
07:04:06 C220.1.1.1  start_connect
07:04:09 C217.1.1  timed out
07:04:13 C222.1.1.1  start_connect
07:04:19 C225.1.1.1  start_connect
07:04:19 C226.1.1  start_connect
### Relaunched app (pid 46125) 07:04:32–07:06:26
07:04:32 C1.1.1 IPv4#35021df8 start_connect
07:04:32 C2.1.1 IPv4#d32adb76 start_connect
07:04:32 C3.1.1.1 IPv4#35021df8 start_connect
07:04:32 C4.1.1.1 IPv4#d32adb76 start_connect
07:04:32 C1.1.1 IPv4#35021df8 connected (WebSocket)
07:04:37 C5.1.1 IPv4#35021df8 start_connect
07:04:38 C5.1.1 IPv4#35021df8 connected (WebSocket)
07:04:40 C2.1.1 IPv4#d32adb76 timed out
07:04:42 C6.1.1 IPv4#d32adb76 start_connect
07:04:50 C6.1.1 IPv4#d32adb76 timed out
07:04:52 C7.1.1.1 IPv4#d32adb76 start_connect
07:04:54 C8.1.1 IPv4#d32adb76 start_connect
07:04:56 C9.1.1.1 IPv4#d32adb76 start_connect
07:05:02 C8.1.1 IPv4#d32adb76 timed out
07:05:02 C10.1.1.1 IPv4#d32adb76 start_connect
07:05:03 C11.1.1 IPv4#35021df8 start_connect
07:05:03 C11.1.1 IPv4#35021df8 connected (WebSocket)
07:05:08 C12.1.1.1 IPv4#d32adb76 start_connect
07:05:09 C13.1.1 IPv4#d32adb76 start_connect
07:05:14 C14.1.1.1 IPv4#d32adb76 start_connect
07:05:17 C13.1.1 IPv4#d32adb76 timed out
07:05:21 C15.1.1.1 IPv4#d32adb76 start_connect
07:05:24 C16.1.1 IPv4#35021df8 start_connect
07:05:26 C17.1.1 IPv4#35021df8 start_connect
07:05:27 C18.1.1 IPv4#d32adb76 start_connect
07:05:32 C19.1.1.1 IPv4#d32adb76 start_connect
07:05:35 C18.1.1 IPv4#d32adb76 timed out
07:05:36 C17.1.1 IPv4#35021df8 timed out
07:05:39 C21.1.1.1 IPv4#d32adb76 start_connect
07:05:39 C20.1.1 IPv4#35021df8 start_connect
07:05:45 C22.1.1.1 IPv4#d32adb76 start_connect
07:05:46 C23.1.1 IPv4#35021df8 start_connect
07:05:47 C20.1.1 IPv4#35021df8 timed out
07:05:48 C24.1.1.1 IPv4#35021df8 start_connect
07:05:51 C25.1.1 IPv4#d32adb76 start_connect
07:05:51 C26.1.1 IPv4#35021df8 start_connect
07:05:53 C23.1.1 IPv4#35021df8 timed out
07:05:56 C24.1.1.1 IPv4#35021df8 timed out
07:05:56 C27.1.1.1 IPv4#d32adb76 start_connect
07:05:57 C28.1.1.1 IPv4#35021df8 start_connect
07:05:59 C25.1.1 IPv4#d32adb76 timed out
07:06:03 C29.1.1.1 IPv4#d32adb76 start_connect
07:06:03 C30.1.1.1 IPv4#35021df8 start_connect
### Per-minute outcome counts 06:40–07:06 (all hosts)
   2 06:41 connected (WebSocket)
   9 06:41 timed out
   2 06:42 connected (WebSocket)
   3 06:42 timed out
   2 06:43 connected (WebSocket)
   6 06:43 timed out
   2 06:44 connected (WebSocket)
   6 06:44 timed out
   2 07:00 connected (WebSocket)
   6 07:00 timed out
  12 07:01 timed out
   9 07:02 timed out
  15 07:03 timed out
   2 07:04 connected (WebSocket)
  11 07:04 timed out
   1 07:05 connected (WebSocket)
  16 07:05 timed out
   2 07:06 timed out

## Phone Tailscale extension (IPNExtension) 06:22–07:08 key lines
06:23:00 [general] - swiftNetMon: reporting path update for : unsatisfied (No network route), interface: en0[802.11], scoped, ipv4, uses wifi, LQM: unknown
06:23:00 [general] - swiftNetMon: reporting path update for pdp_ip0: satisfied (Path is satisfied), interface: pdp_ip0[lte], scoped, ipv4, dns, expensive, uses cell, LQM: good
06:23:00 defaultroute_darwin: updated last known default if from OS, ifName = pdp_ip0 index: 5 (was en0)
06:23:01 LinkChange: major, rebinding: old: interfaces.State{defaultRoute=en0 ifs={en0:[192.168.0.228/24 llu6] ipsec4:[2400:c600:54aa:eefb:149c:1aa:173d:9766/64 llu6] ipsec5:[2400:c600:54aa:eefb:149c:
06:23:01 Rebind; defIf="pdp_ip0", ips=[10.34.248.102/32]
06:23:01 magicsock: closing connection to derp-3 (rebind-default-route-change), age 36m36s
06:23:01 magicsock: disco: node [eHDrr] d:6e5e730e9a3df29a now using 103.234.119.200:22205 mtu=1360 
06:23:01 magicsock: disco: node [HDQrg] d:ccb0c231f74c6079 now using 103.234.119.200:57420 mtu=1360 
06:23:01 control: NetInfo: NetInfo{varies=false ipv6=false ipv6os=true udp=true icmpv4=false derp=#3 portmap= link="" firewallmode=""}
06:23:01 magicsock: derp-3 connected; connGen=1
06:23:08 open-conn-track: timeout opening (TCP 100.102.71.0:50033 => 100.70.236.37:443) to node [HDQrg]; online=yes, lastRecv=0s
06:41:29 magicsock: derp-3 does not know about peer [eHDrr], removing route
06:41:30 magicsock: disco: node [HDQrg] d:ccb0c231f74c6079 now using 103.234.119.200:57420 mtu=1360 
06:41:33 open-conn-track: timeout opening (TCP 100.102.71.0:49532 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=11m34s, lastRecv=4m21s
06:41:34 magicsock: derp-3 does not know about peer [eHDrr], removing route
   (previous line repeated 1 more times)
06:41:38 open-conn-track: timeout opening (TCP 100.102.71.0:49534 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=11m39s, lastRecv=4m26s
06:41:39 magicsock: derp-3 does not know about peer [eHDrr], removing route
06:41:39 open-conn-track: timeout opening (TCP 100.102.71.0:49532 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=11m40s, lastRecv=4m27s
06:41:43 open-conn-track: timeout opening (TCP 100.102.71.0:49535 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=11m43s, lastRecv=4m31s
06:41:44 magicsock: derp-3 does not know about peer [eHDrr], removing route
   (previous line repeated 1 more times)
06:41:45 open-conn-track: timeout opening (TCP 100.102.71.0:49536 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=11m45s, lastRecv=4m33s
06:41:49 magicsock: derp-3 does not know about peer [eHDrr], removing route
06:41:50 open-conn-track: timeout opening (TCP 100.102.71.0:49535 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=11m50s, lastRecv=4m37s
06:41:51 open-conn-track: timeout opening (TCP 100.102.71.0:49537 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=11m51s, lastRecv=4m39s
06:41:55 magicsock: derp-3 does not know about peer [eHDrr], removing route
06:41:55 open-conn-track: timeout opening (TCP 100.102.71.0:49538 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=11m55s, lastRecv=4m43s
06:41:58 open-conn-track: timeout opening (TCP 100.102.71.0:49539 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=11m58s, lastRecv=4m46s
06:42:00 magicsock: derp-3 does not know about peer [eHDrr], removing route
06:42:01 open-conn-track: timeout opening (TCP 100.102.71.0:49538 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=12m2s, lastRecv=4m49s
06:42:03 open-conn-track: timeout opening (TCP 100.102.71.0:49540 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=12m3s, lastRecv=4m51s
06:42:08 magicsock: derp-3 does not know about peer [eHDrr], removing route
   (previous line repeated 8 more times)
06:42:56 open-conn-track: timeout opening (TCP 100.102.71.0:60430 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=12m57s, lastRecv=5m37s
06:43:00 magicsock: derp-3 does not know about peer [eHDrr], removing route
06:43:01 open-conn-track: timeout opening (TCP 100.102.71.0:60433 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=13m2s, lastRecv=5m42s
06:43:03 open-conn-track: timeout opening (TCP 100.102.71.0:60430 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=13m3s, lastRecv=5m43s
06:43:05 magicsock: derp-3 does not know about peer [eHDrr], removing route
06:43:06 open-conn-track: timeout opening (TCP 100.102.71.0:60434 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=13m7s, lastRecv=5m46s
06:43:08 open-conn-track: timeout opening (TCP 100.102.71.0:60435 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=13m8s, lastRecv=5m48s
06:43:10 magicsock: derp-3 does not know about peer [eHDrr], removing route
06:43:13 open-conn-track: timeout opening (TCP 100.102.71.0:60434 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=13m13s, lastRecv=5m53s
06:43:15 magicsock: derp-3 does not know about peer [eHDrr], removing route
   (previous line repeated 5 more times)
06:43:41 open-conn-track: timeout opening (TCP 100.102.71.0:60437 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=13m41s, lastRecv=6m21s
06:43:46 magicsock: derp-3 does not know about peer [eHDrr], removing route
06:43:46 open-conn-track: timeout opening (TCP 100.102.71.0:60440 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=13m46s, lastRecv=6m26s
06:43:48 open-conn-track: timeout opening (TCP 100.102.71.0:60437 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=13m48s, lastRecv=6m28s
06:43:51 open-conn-track: timeout opening (TCP 100.102.71.0:60441 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=13m51s, lastRecv=6m31s
06:43:51 magicsock: derp-3 does not know about peer [eHDrr], removing route
06:43:53 open-conn-track: timeout opening (TCP 100.102.71.0:60442 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=13m53s, lastRecv=6m33s
06:43:56 magicsock: derp-3 does not know about peer [eHDrr], removing route
06:43:57 open-conn-track: timeout opening (TCP 100.102.71.0:60441 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=13m58s, lastRecv=6m38s
06:43:59 open-conn-track: timeout opening (TCP 100.102.71.0:60443 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=13m59s, lastRecv=6m39s
06:44:01 magicsock: derp-3 does not know about peer [eHDrr], removing route
06:44:03 open-conn-track: timeout opening (TCP 100.102.71.0:60444 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=14m3s, lastRecv=6m43s
06:44:05 open-conn-track: timeout opening (TCP 100.102.71.0:60445 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=14m6s, lastRecv=6m46s
06:44:07 magicsock: derp-3 does not know about peer [eHDrr], removing route
   (previous line repeated 1 more times)
06:44:13 open-conn-track: timeout opening (TCP 100.102.71.0:60446 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=14m14s, lastRecv=6m54s
06:44:17 magicsock: derp-3 does not know about peer [eHDrr], removing route
06:44:18 open-conn-track: timeout opening (TCP 100.102.71.0:60450 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=14m19s, lastRecv=6m59s
06:44:20 open-conn-track: timeout opening (TCP 100.102.71.0:60446 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=14m20s, lastRecv=7m0s
06:44:22 magicsock: derp-3 does not know about peer [eHDrr], removing route
06:44:23 open-conn-track: timeout opening (TCP 100.102.71.0:60451 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=14m24s, lastRecv=7m4s
06:44:25 open-conn-track: timeout opening (TCP 100.102.71.0:60452 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=14m25s, lastRecv=7m5s
06:44:27 magicsock: derp-3 does not know about peer [eHDrr], removing route
06:44:30 open-conn-track: timeout opening (TCP 100.102.71.0:60451 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=14m30s, lastRecv=7m10s
06:44:31 open-conn-track: timeout opening (TCP 100.102.71.0:60453 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=14m32s, lastRecv=7m12s
06:44:32 magicsock: derp-3 does not know about peer [eHDrr], removing route
06:44:35 open-conn-track: timeout opening (TCP 100.102.71.0:60454 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=14m35s, lastRecv=7m15s
06:44:37 magicsock: derp-3 does not know about peer [eHDrr], removing route
   (previous line repeated 21 more times)
07:00:41 magicsock: disco: node [HDQrg] d:ccb0c231f74c6079 now using 103.234.119.200:57420 mtu=1360 
07:00:45 open-conn-track: timeout opening (TCP 100.102.71.0:60636 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=30m45s, lastRecv=22m50s
07:00:45 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:00:50 open-conn-track: timeout opening (TCP 100.102.71.0:60639 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=30m50s, lastRecv=22m55s
07:00:50 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:00:51 open-conn-track: timeout opening (TCP 100.102.71.0:60636 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=30m52s, lastRecv=22m57s
07:00:55 open-conn-track: timeout opening (TCP 100.102.71.0:60640 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=30m55s, lastRecv=23m0s
07:00:55 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:00:57 open-conn-track: timeout opening (TCP 100.102.71.0:60641 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=30m57s, lastRecv=23m2s
07:01:01 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:01:01 open-conn-track: timeout opening (TCP 100.102.71.0:60640 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=31m2s, lastRecv=23m7s
07:01:03 open-conn-track: timeout opening (TCP 100.102.71.0:60642 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=31m3s, lastRecv=23m8s
07:01:06 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:01:06 open-conn-track: timeout opening (TCP 100.102.71.0:60643 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=31m7s, lastRecv=23m12s
07:01:09 open-conn-track: timeout opening (TCP 100.102.71.0:60644 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=31m10s, lastRecv=23m15s
07:01:11 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:01:13 open-conn-track: timeout opening (TCP 100.102.71.0:60643 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=31m13s, lastRecv=23m18s
07:01:15 open-conn-track: timeout opening (TCP 100.102.71.0:60645 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=31m15s, lastRecv=23m20s
07:01:16 magicsock: derp-3 does not know about peer [eHDrr], removing route
   (previous line repeated 1 more times)
07:01:21 open-conn-track: timeout opening (TCP 100.102.71.0:60646 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=31m22s, lastRecv=23m27s
07:01:23 open-conn-track: timeout opening (TCP 100.102.71.0:60647 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=31m23s, lastRecv=23m28s
07:01:26 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:01:28 open-conn-track: timeout opening (TCP 100.102.71.0:60648 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=31m28s, lastRecv=23m33s
07:01:29 open-conn-track: timeout opening (TCP 100.102.71.0:60647 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=31m29s, lastRecv=23m35s
07:01:31 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:01:34 open-conn-track: timeout opening (TCP 100.102.71.0:60649 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=31m35s, lastRecv=23m40s
07:01:36 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:01:39 open-conn-track: timeout opening (TCP 100.102.71.0:60650 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=31m39s, lastRecv=23m44s
07:01:41 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:01:44 open-conn-track: timeout opening (TCP 100.102.71.0:60651 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=31m45s, lastRecv=23m50s
07:01:45 open-conn-track: timeout opening (TCP 100.102.71.0:60650 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=31m46s, lastRecv=23m51s
07:01:47 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:01:51 open-conn-track: timeout opening (TCP 100.102.71.0:60652 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=31m51s, lastRecv=23m56s
07:01:52 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:01:56 open-conn-track: timeout opening (TCP 100.102.71.0:60653 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=31m57s, lastRecv=24m2s
07:01:57 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:02:01 open-conn-track: timeout opening (TCP 100.102.71.0:60654 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=32m2s, lastRecv=24m7s
07:02:02 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:02:03 open-conn-track: timeout opening (TCP 100.102.71.0:60653 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=32m3s, lastRecv=24m8s
07:02:07 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:02:08 open-conn-track: timeout opening (TCP 100.102.71.0:60655 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=32m8s, lastRecv=24m13s
07:02:12 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:02:13 open-conn-track: timeout opening (TCP 100.102.71.0:60656 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=32m13s, lastRecv=24m19s
07:02:17 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:02:18 open-conn-track: timeout opening (TCP 100.102.71.0:60657 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=32m19s, lastRecv=24m24s
07:02:20 open-conn-track: timeout opening (TCP 100.102.71.0:60656 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=32m20s, lastRecv=24m25s
07:02:23 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:02:25 open-conn-track: timeout opening (TCP 100.102.71.0:60658 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=32m25s, lastRecv=24m30s
07:02:28 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:02:30 open-conn-track: timeout opening (TCP 100.102.71.0:60659 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=32m30s, lastRecv=24m35s
07:02:33 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:02:35 open-conn-track: timeout opening (TCP 100.102.71.0:60660 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=32m35s, lastRecv=24m40s
07:02:36 open-conn-track: timeout opening (TCP 100.102.71.0:60659 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=32m37s, lastRecv=24m42s
07:02:38 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:02:41 open-conn-track: timeout opening (TCP 100.102.71.0:60661 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=32m42s, lastRecv=24m47s
07:02:43 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:02:48 open-conn-track: timeout opening (TCP 100.102.71.0:60662 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=32m48s, lastRecv=24m53s
07:02:48 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:02:53 open-conn-track: timeout opening (TCP 100.102.71.0:60663 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=32m53s, lastRecv=24m58s
07:02:53 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:02:54 open-conn-track: timeout opening (TCP 100.102.71.0:60662 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=32m55s, lastRecv=25m0s
07:03:03 control: NetInfo: NetInfo{varies= ipv6=false ipv6os=true udp=false icmpv4=false derp=#3 portmap= link="" firewallmode=""}
07:03:19 [general] - swiftNetMon: reporting path update for en0: satisfied (Path is satisfied), interface: en0[802.11], scoped, ipv4, dns, uses wifi, LQM: unknown
07:03:19 defaultroute_darwin: updated last known default if from OS, ifName = en0 index: 15 (was pdp_ip0)
07:03:19 LinkChange: major, rebinding: old: interfaces.State{defaultRoute=pdp_ip0 ifs={ipsec4:[2400:c600:54aa:eefb:149c:1aa:173d:9766/64 llu6] ipsec5:[2400:c600:54aa:eefb:149c:1aa:173d:9766/64 llu6] p
07:03:19 Rebind; defIf="en0", ips=[192.168.0.228/24 fe80::1cf5:fb6b:e4dc:ccb0/64]
07:03:19 magicsock: closing connection to derp-3 (rebind-default-route-change), age 26m2s
07:03:20 magicsock: derp-3 connected; connGen=1
07:03:25 [general] - swiftNetMon: reporting path update for en0: satisfied (Path is satisfied), interface: en0[802.11], scoped, ipv4, dns, uses wifi, LQM: unknown
07:03:27 control: NetInfo: NetInfo{varies= ipv6=false ipv6os=true udp=false icmpv4=false derp=#3 portmap=U link="" firewallmode=""}
07:04:32 magicsock: derp-3 does not know about peer [eHDrr], removing route
   (previous line repeated 12 more times)
07:04:32 magicsock: disco: node [HDQrg] d:ccb0c231f74c6079 now using 192.168.0.226:57420 mtu=1360 
07:04:32 magicsock: disco: node [HDQrg] d:ccb0c231f74c6079 now using 103.234.119.200:57420 mtu=1360 
07:04:32 magicsock: disco: node [HDQrg] d:ccb0c231f74c6079 now using 192.168.0.226:57420 mtu=1360 
07:04:32 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:04:33 control: NetInfo: NetInfo{varies=false ipv6=false ipv6os=true udp=true icmpv4=false derp=#3 portmap=U link="" firewallmode=""}
07:04:37 open-conn-track: timeout opening (TCP 100.102.71.0:60664 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m37s, lastRecv=26m42s
07:04:37 open-conn-track: timeout opening (TCP 100.102.71.0:60666 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m37s, lastRecv=26m42s
07:04:37 open-conn-track: timeout opening (TCP 100.102.71.0:60667 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m37s, lastRecv=26m42s
07:04:37 open-conn-track: timeout opening (TCP 100.102.71.0:60669 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m37s, lastRecv=26m42s
07:04:37 open-conn-track: timeout opening (TCP 100.102.71.0:60671 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m37s, lastRecv=26m42s
07:04:37 open-conn-track: timeout opening (TCP 100.102.71.0:60675 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m37s, lastRecv=26m42s
07:04:37 open-conn-track: timeout opening (TCP 100.102.71.0:60678 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m37s, lastRecv=26m42s
07:04:37 open-conn-track: timeout opening (TCP 100.102.71.0:60681 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m37s, lastRecv=26m42s
07:04:37 open-conn-track: timeout opening (TCP 100.102.71.0:60685 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m37s, lastRecv=26m42s
07:04:37 open-conn-track: timeout opening (TCP 100.102.71.0:60686 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m37s, lastRecv=26m42s
07:04:37 open-conn-track: timeout opening (TCP 100.102.71.0:60688 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m37s, lastRecv=26m42s
07:04:37 open-conn-track: timeout opening (TCP 100.102.71.0:60692 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m37s, lastRecv=26m42s
07:04:37 open-conn-track: timeout opening (TCP 100.102.71.0:60694 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m37s, lastRecv=26m42s
07:04:37 open-conn-track: timeout opening (TCP 100.102.71.0:60696 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m37s, lastRecv=26m42s
07:04:37 open-conn-track: timeout opening (TCP 100.102.71.0:60697 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m37s, lastRecv=26m42s
07:04:37 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:04:37 open-conn-track: timeout opening (TCP 100.102.71.0:60701 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m37s, lastRecv=26m43s
07:04:37 open-conn-track: timeout opening (TCP 100.102.71.0:60703 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m37s, lastRecv=26m43s
07:04:42 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:04:44 open-conn-track: timeout opening (TCP 100.102.71.0:60703 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m44s, lastRecv=26m49s
07:04:44 open-conn-track: timeout opening (TCP 100.102.71.0:60701 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m44s, lastRecv=26m49s
07:04:47 open-conn-track: timeout opening (TCP 100.102.71.0:60705 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m47s, lastRecv=26m52s
07:04:47 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:04:50 open-conn-track: timeout opening (TCP 100.102.71.0:60703 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m50s, lastRecv=26m55s
07:04:52 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:04:53 open-conn-track: timeout opening (TCP 100.102.71.0:60705 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m54s, lastRecv=26m59s
07:04:57 open-conn-track: timeout opening (TCP 100.102.71.0:60706 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m58s, lastRecv=27m3s
07:04:58 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:04:59 open-conn-track: timeout opening (TCP 100.102.71.0:60707 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=38m59s, lastRecv=27m4s
07:05:01 open-conn-track: timeout opening (TCP 100.102.71.0:60708 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=39m2s, lastRecv=27m7s
07:05:03 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:05:05 open-conn-track: timeout opening (TCP 100.102.71.0:60707 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=39m5s, lastRecv=27m10s
07:05:07 open-conn-track: timeout opening (TCP 100.102.71.0:60709 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=39m7s, lastRecv=27m12s
07:05:08 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:05:13 open-conn-track: timeout opening (TCP 100.102.71.0:60711 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=39m13s, lastRecv=27m19s
07:05:13 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:05:14 open-conn-track: timeout opening (TCP 100.102.71.0:60712 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=39m14s, lastRecv=27m20s
07:05:18 magicsock: derp-3 does not know about peer [eHDrr], removing route
07:05:19 open-conn-track: timeout opening (TCP 100.102.71.0:60713 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=39m19s, lastRecv=27m25s
07:05:25 control: NetInfo: NetInfo{varies= ipv6=false ipv6os=true udp=false icmpv4=false derp=#3 portmap=U link="" firewallmode=""}
07:07:27 magicsock: derp-3 does not know about peer [eHDrr], removing route
   (previous line repeated 14 more times)
07:07:27 magicsock: disco: node [HDQrg] d:ccb0c231f74c6079 now using 192.168.0.226:57420 mtu=1360 
07:07:27 magicsock: derp-3 does not know about peer [eHDrr], removing route
   (previous line repeated 3 more times)
07:07:32 open-conn-track: timeout opening (TCP 100.102.71.0:60712 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=41m33s, lastRecv=29m8s
07:07:32 open-conn-track: timeout opening (TCP 100.102.71.0:60714 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=41m33s, lastRecv=29m8s
07:07:32 open-conn-track: timeout opening (TCP 100.102.71.0:60713 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=41m33s, lastRecv=29m8s
07:07:32 open-conn-track: timeout opening (TCP 100.102.71.0:60715 => 100.70.236.37:443) to node [HDQrg]; online=yes, lastRecv=5s
07:07:32 open-conn-track: timeout opening (TCP 100.102.71.0:60717 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=41m33s, lastRecv=29m8s
07:07:32 open-conn-track: timeout opening (TCP 100.102.71.0:60718 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=41m33s, lastRecv=29m8s
07:07:32 open-conn-track: timeout opening (TCP 100.102.71.0:60719 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=41m33s, lastRecv=29m8s
07:07:32 open-conn-track: timeout opening (TCP 100.102.71.0:60721 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=41m33s, lastRecv=29m8s
07:07:32 open-conn-track: timeout opening (TCP 100.102.71.0:60724 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=41m33s, lastRecv=29m8s
07:07:32 open-conn-track: timeout opening (TCP 100.102.71.0:60726 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=41m33s, lastRecv=29m8s
07:07:32 open-conn-track: timeout opening (TCP 100.102.71.0:59886 => 100.67.205.123:443) to node [eHDrr]; online=no, lastseen=41m33s, lastRecv=29m8s
07:07:33 magicsock: derp-3 does not know about peer [eHDrr], removing route

## Phone wifid: association uptime reset only once today (07:03:18, was 8381 s). RSSI 07:03–07:06: -38..-58 dBm, TxFail 0, Cca 3–14 (one 61 spike 07:04:08), RxRetries mostly <50 with bursts 280–1143 at 07:04:03–08 and 07:06:20. Wi-Fi at 06:23 reported 'unsatisfied (No network route)' on en0 while still associated; default route moved to pdp_ip0 (LTE) until 07:03:19.

## App scene phases (from UIKit deactivation reasons): app backgrounded 06:44:31 → foreground 07:00:40; 07:01:09–07:01:11; 07:01:48–07:01:49; 07:03:15–07:03:19; user-quit 07:04:24; relaunch 07:04:32; user-quit 07:06:26.

## App-side facts
- App logs its reason codes with os Logger .info → not persisted; not present in log collect. Only Apple's network layer lines were available.
- HostConnection (events link) cycles the socket with 1001 going-away on foreground return; terminal cancels; both redial immediately. Host sees 1001 + 1006 pairs.
- Host-side server heartbeat (new in 0.1.18): terminates events socket after 2 unanswered pings (45 s) → 'byHost=true' lines above.
