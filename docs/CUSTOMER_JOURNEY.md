# Mocha customer journey

**Status:** Product hypothesis for validation
**Updated:** 2026-08-19
**Primary journey:** Leave an agent running, intervene safely from a phone, then get out of the way

This journey is the product spine for Mocha. It describes the experience we must make excellent before expanding into a broad mobile IDE. It is based on the founder's workflow and desk research; the assumptions marked below still require observation with external users.

## 1. The job in one sentence

When coding work continues after I leave my computer, help me notice the session that genuinely needs me, understand just enough context, act safely in seconds, and trust that the work will continue when I put my phone away.

## 2. Primary end-to-end journey

| Stage | User context and goal | User question or anxiety | Mocha response | Success signal |
| --- | --- | --- | --- | --- |
| 1. Prepare at the desk | The user already has Codex, Claude Code, another CLI, tmux, or Herdr running on a computer they control. They want remote access without adopting a new agent runtime. | “Will this change how my agent runs or touch its login?” | Install the Mocha host, discover existing durable sessions, recommend Tailscale, and state clearly that official CLIs keep their own authentication and execution. | A real existing session appears without restarting the agent or copying provider credentials. |
| 2. Pair the phone | The user is still near the computer and can verify both devices. | “Am I accidentally exposing shell access?” | Scan a short-lived QR code, show the host name and fingerprint on both devices, issue a named per-device credential, store it in Keychain, and explain revocation. | Pairing and a private-path connection test complete in under two minutes. |
| 3. Leave the computer | The laptop or desktop remains awake while the phone disconnects, locks, or changes networks. | “Will the process die when the app closes?” | tmux or Herdr owns session lifetime. The app explicitly says it is safe to leave and never implies that the phone owns the process. | The agent continues after the app is force-closed or the phone loses connectivity. |
| 4. Return from the phone | A notification arrives later, or the user opens Mocha to check progress. They may be walking, commuting, or using one hand. | “What needs me now?” | Face ID, then an immediate cached attention view: needs action first, followed by working/recent sessions. Show host, project, agent identity, freshness, and connection state without a dashboard preamble. | The correct session is identified in under five seconds. |
| 5. Inspect before acting | The user needs enough evidence to avoid answering the wrong prompt. | “What happened, and is this state trustworthy?” | Present a bounded recent preview, state provenance, timestamp, changed-file or tool context when authoritative, and a clear stale/unknown state when it is not. | The user can explain why the session needs them before sending input. |
| 6. Make a short intervention | The common action is approve, deny, answer, steer, interrupt, or send a short prompt. | “Can I do this without fighting a tiny terminal?” | Offer capability-gated structured actions or Chat when available, plus a deliberate multiline composer, dictation later, confirmation for risky actions, and visible target identity. | Most interventions finish without opening the full terminal or laptop. |
| 7. Escalate to terminal | Structured context is missing, ambiguous, or insufficient. | “Can I reach the exact real session—not a copy?” | Open the same host/session/window/pane in a native GhosttyKit terminal. Keep terminal content opaque and high-contrast; use Liquid Glass only for surrounding navigation and controls. | One tap reaches the exact live PTY with no hidden second agent. |
| 8. Leave again | The user has sent the answer and wants to return to real life. | “Did it take, and can I close this safely?” | Show the resulting state transition or fresh output, then make dismissal natural. Detaching never terminates the process. | The phone session ends while work continues on the host. |
| 9. Recover when reality is messy | A host sleeps, Tailscale uses a slower route, the network changes, or state becomes stale. | “Is my command lost, duplicated, or still pending?” | Mark stale immediately, disable ambiguous sends, show last seen/path/latency, reconnect and resubscribe, fetch fresh state, and never silently replay uncertain input. | Recovery restores the exact target or explains a concrete next action without duplicate input. |

## 3. Primary happy path

Desk setup → pair once → leave agent running → phone opens to “Needs you” → inspect trustworthy context → approve or answer → observe the session resume → close phone.

The design target is a **20–60 second visit**, not a long mobile coding session. Terminal access remains complete because it is the universal compatibility and recovery layer.

## 4. First-run journey

**Locked visual reference:** [`assets/agent-deck-v1-pairing-flow.png`](./assets/agent-deck-v1-pairing-flow.png). The approved structure is scan-first: keep the opening explanation brief, place the shell-access disclosure and fingerprint verification immediately before consent, and defer optional connection choices to fallback paths.

1. **Explain the boundary.** “Your agents and their logins stay on your computer. Mocha connects to that computer.”
2. **Choose the first host.** The desktop command creates a short-lived pairing QR code; manual entry is fallback only.
3. **Verify identity.** Match host name and fingerprint before granting the phone shell-capable access.
4. **Test the path.** Reveal identity, TLS, path, latency, and durable-session checks progressively during the pairing handshake; do not add a separate tutorial step unless the connection needs intervention.
5. **Discover work.** Import existing tmux/Herdr sessions and label semantic state only when an authoritative source exists.
6. **Run a guided intervention.** Demo mode teaches attention, inspection, action, terminal fallback, detach, and reconnect without requiring a live provider account.
7. **Finish with trust controls.** Show the paired device name, where to revoke it, and a clear reminder that closing Mocha does not stop tmux/Herdr sessions.

Onboarding should not ask users to sign in to Claude, ChatGPT, Codex, or another model provider. The installed official tools continue to own those accounts.

## 5. Critical recovery journeys

### Host is offline or asleep

- Show last-seen time and the most likely cause without pretending to know more than the host reported.
- Keep cached session metadata visibly stale.
- Offer retry and a short host-side checklist; never suggest exposing a public port.

### Tailscale path is slow

- Show direct, peer-relay, relay, or unknown when evidence exists, plus latency and recent path changes.
- Keep the user in context while reconnecting; do not drop back to the home screen.
- Explain that a relay can be slower and provide diagnostics after the intervention, not as a modal interruption.

### Input status is ambiguous

- Freeze sending until the app knows whether the socket accepted the input.
- Preserve unsent draft text locally.
- Never automatically replay possibly-sent terminal bytes after reconnect.

### Agent state cannot be trusted

- Display `Unknown` or `Terminal only`, including the reason and freshness.
- Do not synthesize approvals or chat messages from arbitrary screen scraping.
- Keep exact terminal resume available.

### Credential is revoked or phone is lost

- Fail closed, clear decrypted in-memory credentials, and explain that the host rejected this device.
- Allow the host owner to revoke individual devices without rotating every other phone or computer.

## 6. Moments of truth

1. **The first remote attach:** latency and terminal fidelity establish whether the product is credible.
2. **The first correct attention alert:** the user must understand both what needs them and why Mocha believes it.
3. **The first network switch:** the session must recover without duplicate or missing input.
4. **The first terminal fallback:** the user must land in the exact live session, not a reconstructed transcript.
5. **The first security question:** the app must make local execution, provider authentication, transport, and revocation understandable.

## 7. Experience rules derived from the journey

- Home is an attention inbox, not an analytics dashboard.
- Cached state can make launch fast, but freshness must remain visible.
- Every screen preserves host, project, session, and provider context.
- Structured actions are capability-gated; terminal fallback is universal.
- Liquid Glass belongs to navigation, layered controls, transitions, and lightweight cards. Terminal output, diffs, code, and high-density diagnostics use opaque readable surfaces.
- One-handed actions have large targets and do not depend on hover, precise text selection, or hidden gestures.
- Closing, backgrounding, or losing the phone must never own or end the host process.

## 8. Journey measurements

| Moment | Proposed measure |
| --- | --- |
| Pair | Median time from QR scan to verified first host; pairing failure reason distribution. |
| Find | Median app-open to correct-session selection; mis-selection rate. |
| Understand | Percentage of users who can correctly explain the requested intervention and state provenance. |
| Act | Percentage of interventions completed without a laptop; percentage completed without full terminal. |
| Recover | Reconnect time, duplicate-input incidents, lost-draft incidents, wrong-target incidents. |
| Trust | False attention labels; credential/revocation comprehension; public-exposure misconfiguration rate. |
| Leave | Percentage of visits under 60 seconds that still resolve the intended intervention. |

## 9. Validation plan

- Observe five target users performing first pairing with no verbal coaching.
- Test the primary happy path with Codex, Claude Code, and an unknown terminal CLI.
- Force Wi-Fi-to-cellular switching, host sleep, app termination, stale state, revoked credentials, and a relay path.
- Ask users to identify where the agent runs, where provider credentials live, whether closing the phone ends work, and why a session is labeled `Needs attention`.
- Prototype the journey first with standard native hierarchy, then test refinements on time-to-attention, trust, one-handed reach, and perceived terminal seriousness—not aesthetic preference alone.

## 10. Assumptions to validate

- The most valuable visits are brief interventions rather than extended terminal use.
- Users will install a small host and Tailscale to obtain speed and privacy.
- “Needs attention” can be made trustworthy enough through Herdr, hooks, and documented provider protocols.
- A provider-neutral session model can stay understandable while Codex and Claude Code receive first-class identity and setup.
- System-provided Liquid Glass in the functional layer will feel current and native without reducing the legibility expected from a serious terminal tool.
