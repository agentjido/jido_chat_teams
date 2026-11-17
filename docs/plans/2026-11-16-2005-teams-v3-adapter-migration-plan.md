---
title: Teams adapter Jido Chat V3 migration
type: implementation-plan
date: 2026-11-16
last_reviewed: 2026-11-17
artifact_contract: kata-plan/v1
artifact_readiness: completed
domain: software
execution: code
product_contract_source: approved-goal
---

# Teams Adapter Jido Chat V3 Migration

## Goal Capsule

- Objective: Migrate Microsoft Teams to the current Jido Chat V3 Client,
  Signal, Adapter, and host-owned webhook contracts without a V2 compatibility
  API.
- Means: Preserve Bot Connector Activity Protocol sending, conversation
  references, JWT validation, card rendering, bounded attachment downloads,
  and the current lifecycle-event branch work. Replace V2 callbacks and event
  wrappers with typed operation dispatch and deterministic public facts.
- Authority: Local Teams package and local Jido Chat checks. No live provider
  call, credential use, branch change, commit, push, release, or remote update.
- Stop conditions: Stop before Graph becomes a required message path, a
  provider branch enters core, signed media URLs enter public Signals, or an
  unapproved remote action.

## Starting Evidence

- Preserve `feat/lifecycle-events` at `4124103`. It is one local commit ahead
  of `origin/pr-14`; the commit fixes an options-loader timing race.
- The clean branch has 78 passing offline tests and two excluded live tests.
- The adapter is a 1,000-line V2 callback module. It uses removed event and
  webhook values, fallback capabilities, application-environment credentials,
  and a Jido Messaging ownership statement.
- Provider boundaries already exist for conversation references, OAuth, JWT
  verification, Activity Protocol transport, cards, modals, and bounded media.

## Product Contract

- **R1:** Select sibling `../jido_chat` and consolidated Jido V3 at
  `ec96da6015b4b1e5a1642d50651235d9d52808ec`.
- **R2:** Keep only current stateless Adapter callbacks and explicit
  `:native | :unsupported` operation statuses.
- **R3:** Store app credentials in `Client.credentials`. Do not read the
  application environment. Pass credentials to transport and webhook helpers
  through private local values.
- **R4:** Keep native message, edit, delete, typing, metadata, thread,
  attachment download, and dynamic-option behavior where the V3 core has a
  matching request and result.
- **R5:** Normalize messages, edits, deletes, reactions, actions, and option
  requests into stable ordered V3 facts. Do not put raw Activity payloads,
  authorization headers, app secrets, access tokens, or pre-authenticated file
  URLs in public Signals.
- **R6:** Keep HTTP host-owned. `Jido.Chat.Teams.Webhook` validates a Bot
  Connector JWT before normalization and returns plain provider response data.
- **R7:** Keep Microsoft Graph optional and outside the primary path. Do not
  add a Teams process tree, retry queue, room registry, or storage layer.
- **R8:** Remove V2 event wrappers, direct adapter send APIs, fallback
  behavior, global credential lookup, and retired Messaging ownership text.
- **R9:** Offline tests cover the Adapter Test Kit, all native operations,
  normalization identities, JWT admission, Activity request shape, bounded
  media, conversation references, cards, and unsupported operations.
- **R10:** Tests, coverage execution, quality, docs, production compile,
  unused dependency, dependency tree, compile graph, source scan, diff check,
  and the Elixir design review pass.

## Implementation Units

1. Select local Jido Chat V3 and refresh the dependency graph.
2. Make OAuth and transport credentials explicit and remove global lookup.
3. Add V3 Operations and Normalizer modules around conversation references.
4. Add the pure webhook verification and response helper.
5. Replace the Adapter, remove V2 paths, and update tests and documents.
6. Run all offline gates and the Elixir design review, fix every supported
   finding, and repeat affected checks.

## Definition of Done

- R1 through R10 have current evidence.
- The `4124103` lifecycle and timing-race behavior remains covered.
- No live provider call, branch change, or remote change occurred.

## Completion Evidence

- The package selects sibling Jido Chat V3 and consolidated Jido at
  `ec96da6015b4b1e5a1642d50651235d9d52808ec`.
- The full offline suite passes with 43 tests and one excluded live test. The
  Adapter Test Kit passes 11 contract tests.
- `mix quality`, strict Credo, Dialyzer, Doctor, documentation, coverage,
  production warnings-as-errors compilation, unused-dependency checks, and
  the compile-cycle check pass. Measured coverage is 75.3%.
- `git diff --check` passes. A source scan finds no V2 event wrapper,
  application-environment credential lookup, token-cache process, or
  `jido_messaging` reference.
- The final Elixir design review found no remaining supported issue. The
  adapter is stateless, HTTP remains host-owned, and private provider values do
  not enter public Signals.
- No live provider call, branch change, commit, push, release, or remote update
  occurred.
