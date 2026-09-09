# Tavi product source of truth

This folder is the planning and research baseline for Tavi. It supersedes the early product note in [`PRODUCT.md`](./PRODUCT.md) whenever the documents disagree.

## Start here

- [`ROADMAP.md`](./ROADMAP.md) — the active phase-by-phase build plan and execution order; supersedes the implementation plan's phase ordering.
- [`CONNECTION_ARCHITECTURE.md`](./CONNECTION_ARCHITECTURE.md) — the connection plan after the 2026-09-09 Tailscale stall (#119): SLIs, identity, session layer, routes, relay, phases, and the decisions the owner is asked for; evidence and the three Astra review rounds in [`research/connection-2026-09/`](./research/connection-2026-09/README.md). **Pending the owner's decision; overrides the "Tailscale direct-first, no hosted relay" lines in the PRD and strategy doc only once decided.**
- [`DEVELOPMENT.md`](./DEVELOPMENT.md) — the practical build/deploy/verification loop (host service, simulator harness, device installs, test gotchas).
- [`HERDR_INTEGRATION.md`](./HERDR_INTEGRATION.md) — the verified Herdr socket API contract and its traps.
- [`DEVELOPMENT_PRINCIPLES.md`](./DEVELOPMENT_PRINCIPLES.md) — non-negotiable engineering policy for code quality, architecture, state, security, concurrency, reliability, testing, privacy, accessibility, dependencies, performance, and releases.
- [`../protocol/README.md`](../protocol/README.md) — platform-neutral HTTP/WebSocket contract and compatibility home for native clients.
- [`agent-deck-product-plan.html`](./agent-deck-product-plan.html) — polished visual review document.
- [`RESEARCH_AND_STRATEGY.md`](./RESEARCH_AND_STRATEGY.md) — market research, product thesis, positioning, and recommendations.
- [`PRD.md`](./PRD.md) — product requirements and release boundaries.
- [`CUSTOMER_JOURNEY.md`](./CUSTOMER_JOURNEY.md) — end-to-end user journey, recovery paths, moments of truth, and validation measures.
- [`V1_SCREEN_AND_NAVIGATION_MAP.md`](./V1_SCREEN_AND_NAVIGATION_MAP.md) — locked V1 screen inventory, route hierarchy, sheets, deep links, and recovery states.
- [`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md) — evidence-gated execution plan and test strategy.
- [`FEATURE_LANDSCAPE.md`](./FEATURE_LANDSCAPE.md) — researched feature inventory, competitor evidence, and priorities.
- [`CHAT_UI_AND_AGENT_ARCHITECTURE.md`](./CHAT_UI_AND_AGENT_ARCHITECTURE.md) — compliance boundaries, optional chat UI, and agent-neutral capability architecture.

## Working rule

When a product decision changes, update the PRD and the decision log in the research document before implementation. The HTML report is a review surface; the Markdown documents remain the maintainable source.

When implementation and [`DEVELOPMENT_PRINCIPLES.md`](./DEVELOPMENT_PRINCIPLES.md) disagree, the implementation must change or the principle must be explicitly revised by the project owner. Silent exceptions are not allowed.

## Locked terminal baseline

The native iOS client uses a pinned GhosttyKit build rendered with Metal, following the proven Moshi/Remux system pattern while retaining Tavi's direct Tailscale host protocol. Tavi owns the reproducible XCFramework and downstream patches; SwiftTerm is contingency-only.
