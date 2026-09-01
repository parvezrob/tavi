# Tavi development principles

**Status:** Non-negotiable engineering policy
**Updated:** 2026-08-19
**Applies to:** production code, tests, build tooling, host services, mobile clients, and reviewed prototypes

These principles are release constraints, not preferences. A change that violates them is not complete, even if it appears to work.

## 1. Production-grade quality comes first

- Build every production path for correctness, security, failure, recovery, and maintenance—not only the happy path.
- Handle errors deliberately. Use bounded retries, timeouts, cancellation, and idempotency where the operation requires them.
- Validate untrusted input at the boundary and preserve least-privilege access.
- Add tests in proportion to risk. Critical behavior, state transitions, persistence, authentication, reconnection, and destructive actions require automated coverage.
- Do not ship placeholder behavior, silent failure, unexplained magic constants, or unresolved critical-path TODOs.
- Performance and resource use are product quality. Measure latency, memory, CPU, battery, and reconnect behavior on representative devices.

## 2. Prefer clean code over clever code

- Choose the simplest design that correctly expresses the domain and satisfies known requirements.
- Prefer explicit control flow, descriptive names, small focused units, and unsurprising data structures.
- Do not compress logic merely to reduce line count.
- Avoid hidden side effects, implicit global state, and behavior that depends on undocumented ordering.
- Comments explain intent, invariants, constraints, and tradeoffs. They do not compensate for unreadable code.

## 3. Readability is a requirement

- A competent contributor should be able to understand a change without reconstructing the author's thought process.
- Keep public interfaces narrow and make invalid states difficult or impossible to represent.
- Keep functions and types at one useful level of abstraction.
- Use the project's established vocabulary consistently across code, protocol schemas, tests, logs, and documentation.
- Optimize for reviewability: focused changes, clear boundaries, and evidence for non-obvious decisions.

## 4. Reuse before invention

- Search the repository and dependency surface before creating a new component, service, utility, protocol type, or abstraction.
- Reuse or extend an existing suitable implementation instead of creating a parallel version.
- Maintain one canonical implementation for each concept. Remove accidental duplication rather than allowing variants to drift.
- Build components around a clear responsibility, a small interface, and composition so they can be reused safely.
- Reuse does not justify a poor abstraction. Do not force unrelated behavior into one component or create speculative frameworks for hypothetical future use.
- Introduce a new component only when no existing component can satisfy the requirement cleanly. Record the reason in the review when the overlap is not obvious.

## 5. Follow SOLID design principles

- **Single responsibility:** each unit has one clear reason to change.
- **Open/closed:** prefer extension through stable seams over repeated modification of central logic.
- **Liskov substitution:** implementations must honor the full behavioral contract of the abstraction they implement.
- **Interface segregation:** consumers depend only on the capabilities they use.
- **Dependency inversion:** core policy depends on abstractions; platform, network, storage, terminal, and provider details remain replaceable adapters.

SOLID is a tool for clarity, testing, and change isolation. Do not create layers, protocols, or indirection that do not reduce real coupling.

## 6. Preserve ACID properties for durable state

Any operation that changes persistent product state must have an explicit consistency boundary.

- **Atomicity:** a multi-step state change completes fully or leaves no partial committed result.
- **Consistency:** every committed state satisfies documented invariants and schema constraints.
- **Isolation:** concurrent operations cannot observe or produce invalid intermediate state.
- **Durability:** acknowledged writes survive process restart and the documented failure model.

Use real database transactions when a transactional store is involved. For files or distributed workflows, use the closest correct equivalents—such as write-then-atomic-rename, version checks, idempotency keys, durable journals, or compensating operations—and document where true ACID guarantees end. Never describe an eventually consistent workflow as ACID.

## 7. React code does not use effects

Application-authored React code must not use `useEffect` or disguise an effect inside a custom hook. `useLayoutEffect` is not an acceptable workaround. Third-party library internals are outside this rule, but our integration code remains subject to it.

Use the appropriate alternative:

- derive values during render instead of synchronizing derived state;
- perform user-initiated work in event handlers;
- use reducers or explicit state machines for transitions;
- use framework loaders, actions, or a query cache for remote data;
- use `useSyncExternalStore` for subscriptions to external stores;
- use keys or component boundaries to reset lifecycle state;
- move imperative platform integration behind a non-React adapter with an explicit owner and lifecycle.

If a proposed React feature appears to require an effect, stop and redesign the ownership boundary before implementation. Do not add an exception silently.

Tavi does not currently ship a React client. This rule remains the acceptance policy if React is introduced for a future project surface.

## 8. Security and privacy are designed in

- Threat-model every trust boundary: phone, host, private network, local processes, providers, stored credentials, notifications, logs, and exported diagnostics.
- Default to least privilege, deny by default, secure defaults, and explicit user authorization for sensitive or destructive actions.
- Keep credentials in platform secure storage. On Apple platforms, use Keychain with the most restrictive accessibility compatible with the required behavior.
- Never store or emit tokens, prompts, terminal contents, private paths, credentials, or other sensitive payloads in logs, analytics, notifications, crash metadata, or screenshots by default.
- Use platform cryptography and authentication APIs. Do not invent cryptographic primitives, secret formats, certificate validation, or authentication schemes.
- Treat the [OWASP Mobile Application Security Verification Standard](https://mas.owasp.org/MASVS/) as the minimum mobile security baseline and document the applicable controls before release.
- Security-sensitive behavior requires negative tests, revocation tests, and a documented failure mode—not only a successful-path test.

## 9. Make invalid states impossible

- Represent domain states and transitions explicitly with types, enums, and state machines rather than unrelated Boolean flags.
- Pairing, authentication, connection, session, provider, recovery, and destructive-action flows must define their valid states, allowed transitions, ownership, and terminal states.
- Validate untrusted data at every network, process, persistence, provider, and platform boundary.
- Prefer constructors and APIs that cannot produce an invalid value. If an invariant cannot be encoded in the type system, enforce it once at the owning boundary and test it.
- Do not silently coerce malformed or contradictory state into an apparently successful result.

## 10. Concurrency is safe by construction

- Build Swift targets in Swift 6 language mode with complete concurrency checking enabled locally. GitHub-hosted CI must not build GhosttyKit or the iOS app without explicit owner approval; native gates run locally and on physical devices until an approved artifact strategy exists.
- Give mutable state one explicit isolation domain and owner. Prefer immutable values, value semantics, structured concurrency, actors, and `Sendable` boundaries.
- UI state and updates belong to the main actor; network, persistence, protocol, and rendering work must not block it.
- Cancellation and deadlines propagate through the complete operation tree. Unstructured or detached tasks require a documented lifetime, owner, cancellation path, and review justification.
- `@unchecked Sendable`, `nonisolated(unsafe)`, hidden locks, and other compiler-safety escape hatches are forbidden unless the safety invariant is documented beside the code and exercised by tests.
- Actor isolation prevents data races but does not make work across an `await` suspension point atomic. Revalidate mutable assumptions after suspension and keep true critical sections synchronous.
- Follow the official [Swift data-race safety model](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/dataracesafety/) instead of recreating a thread-management model with ad hoc queues.

## 11. Failure is a normal product state

- Design offline, reconnecting, stale, revoked, incompatible, overloaded, cancelled, partially completed, and provider-unavailable behavior alongside the happy path.
- Use bounded retries, exponential backoff with jitter, timeouts, cancellation, backpressure, and idempotency where their semantics are correct.
- Never automatically replay terminal input when delivery is ambiguous. Requiring the user to resend is safer than duplicating a command.
- Never swallow an error or replace it with an empty state that looks successful. Convert failures into typed domain errors with a useful recovery action.
- Recovery must preserve user intent and durable session ownership across app backgrounding, network changes, host sleep, process restart, and version mismatch.
- Degraded operation must be honest: unknown or stale state is labeled as such and is never presented as current fact.

## 12. Every resource has one owner

- Every socket, task, timer, observer, terminal surface, PTY attachment, file handle, stream, and subscription has one explicit owner and a deterministic teardown path.
- Resource lifetime follows the owning domain, not an incidental view callback. A view disappearing must not accidentally end a durable remote session.
- Starting an operation must define how it finishes, fails, times out, and is cancelled.
- Cleanup is idempotent and safe after partial initialization.
- Repeated creation, backgrounding, foregrounding, switching, and destruction must be stress-tested for leaks, duplicate callbacks, orphaned tasks, and use-after-teardown behavior.

## 13. Version every durable boundary

- Version network protocols, persisted schemas, Keychain records, provider capabilities, exported diagnostics, fixtures, and other durable interchange formats.
- Every schema change requires a tested migration, an explicit backward-compatibility strategy, or a deliberate reset path approved as a product decision.
- Client and host negotiate capabilities and minimum compatible versions. Incompatibility produces a specific, actionable error instead of undefined behavior.
- Readers tolerate documented additive fields where safe; writers never assume every peer upgraded simultaneously.
- Compatibility fixtures and contract tests are the authority for supported behavior.

## 14. Tests are executable contracts

- Tests verify externally meaningful behavior, invariants, state transitions, and failure handling rather than private implementation details.
- Every fixed defect receives a regression test that fails without the fix.
- Authentication, authorization, revocation, migrations, protocol compatibility, reconnection, destructive actions, cancellation, and persistence require automated coverage.
- Tests are isolated, deterministic, and repeatable. A flaky, disabled, or silently skipped required test is a defect.
- Use the smallest useful test level, then add integration, UI, security, and physical-device coverage where crossing a real boundary is the risk.
- Terminal rendering, lifecycle, memory pressure, network switching, backgrounding, thermal behavior, and hardware input must be qualified on representative physical devices.
- Coverage percentage is supporting evidence, not the goal; critical behavior must be covered regardless of the aggregate number.

## 15. Observability without surveillance

- Use structured events, stable error identifiers, correlation identifiers, and explicit severity so failures can be diagnosed without reconstructing sensitive user activity.
- Redact at the source. Tokens, terminal output, prompts, file contents, private paths, credentials, and provider payloads do not enter logs or analytics by default.
- Measure product health such as connection time, reconnect attempts, latency, crashes, memory, thermal state, protocol failures, and version compatibility without collecting work content.
- Never use an empty `catch`, silent fallback, or generic success result to hide an operational failure.
- User-exported diagnostics are local-first, previewable, redacted, and shared only through explicit action.
- Every metric and log field has a documented purpose, retention policy, sensitivity classification, and owner.

## 16. Performance has enforceable budgets

- Define measurable budgets for launch, first terminal paint, input latency, reconnect time, frame rate, memory, CPU, thermal load, network use, and battery impact in the PRD or release quality gates.
- Measure before optimizing and retain reproducible benchmarks for critical paths.
- Test representative low-end and current devices, long-running sessions, high-output terminals, large scrollback, poor networks, and repeated lifecycle transitions.
- A sustained regression beyond an agreed release budget is a defect and blocks release unless the product owner records an explicit tradeoff.
- Performance changes must preserve correctness, readability, security, and accessibility. Cleverness is not justified by an unmeasured speed claim.
- Use repeatable performance tests, including [XCTest performance measurements](https://developer.apple.com/documentation/xctest/performance-tests), and record device and environment assumptions.

## 17. Accessibility is correctness

- Build Dynamic Type, VoiceOver semantics, sufficient contrast, Reduce Motion, keyboard navigation, focus behavior, and usable touch targets into components from the beginning.
- Prefer system controls and semantic APIs when they satisfy the interaction; custom visuals must preserve equivalent behavior.
- Accessibility labels describe purpose and state, not merely the visible icon.
- Core journeys must remain operable with assistive technology, large text, reduced motion, and hardware keyboards.
- Accessibility regressions block release just like functional regressions.
- Externalized user-facing text must be localization-ready even before additional languages ship.

## 18. Dependencies are liabilities until reviewed

- Prefer platform capabilities and small replaceable adapters over dependencies for trivial functionality.
- Every production dependency requires a documented purpose, owner, license review, security review, maintenance assessment, and removal strategy.
- Pin critical dependencies and build inputs to reviewed versions or commits. GhosttyKit requires a reproducible XCFramework, recorded upstream commit, checksums, and an explicit downstream patch set.
- Commit lockfiles, review transitive changes, automate vulnerability detection, and update deliberately rather than accepting floating upgrades.
- Builds must be reproducible from version-controlled inputs. Record provenance for release artifacts using the concepts in the [SLSA specification](https://slsa.dev/spec/v1.2/).
- No dependency may receive broader filesystem, network, credential, or process access than its responsibility requires.

## 19. Main is always releasable

- Every change passes formatting, static analysis, strict compiler checks, tests, security checks, and production builds before merge.
- Keep changes small, coherent, and reviewable. Separate structural refactoring from behavior changes when combining them obscures risk.
- Do not merge placeholders, unexplained warnings, disabled required tests, unresolved critical TODOs, or known release-blocking defects.
- Risky integrations and optional provider capabilities require a kill switch or safe rollback path that does not disable the universal terminal fallback.
- Release artifacts come from reviewed version-controlled inputs and an automated, documented build path.
- The default branch must be safe to build, test, and release at any time.

## 20. Decisions and code change together

- Record consequential architecture and product decisions in an ADR or the maintained decision log, including context, chosen option, alternatives, consequences, owner, and reversal conditions.
- Update documentation, protocol fixtures, migrations, and tests in the same change as the behavior they describe.
- Maintain one authoritative source for each decision or contract and link to it rather than duplicating competing descriptions.
- Temporary decisions and technical debt require a named owner, bounded scope, removal condition, and mechanism preventing further adoption.
- If implementation evidence invalidates a decision, revise the decision explicitly; do not let code silently become the new policy.

## 21. Definition of done

A change is complete only when:

1. it follows these principles and the product, privacy, security, and accessibility boundaries;
2. an existing reusable implementation was considered before a new one was created;
3. valid states, invariants, ownership, failure, recovery, cancellation, and concurrency behavior are explicit;
4. durable state and protocol changes include compatibility, migration, and rollback behavior;
5. relevant unit, contract, integration, security, performance, and physical-device evidence exists in proportion to risk;
6. formatting, static analysis, strict compiler checks, tests, security checks, and production builds pass;
7. logs, metrics, notifications, crash data, and diagnostics have been checked for sensitive content;
8. dependency and permission changes have been justified and reviewed;
9. public behavior, quality-budget impact, and consequential decisions are documented in their authoritative source;
10. temporary compatibility or technical debt is named, scoped, owned, and prevented from spreading;
11. the change has a safe release, failure, and rollback path; and
12. the default branch remains releasable.
