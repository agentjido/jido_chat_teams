# AGENTS.md - Jido Chat Teams Development Guide

`jido_chat_teams` is the Microsoft Teams adapter for `Jido.Chat`.

## Commands

- `mix setup` - Fetch dependencies.
- `mix test` - Run the default non-live test suite.
- `mix test --include live` - Run explicitly enabled live Microsoft Teams tests.
- `mix quality` - Run the package quality gate.
- `mix coveralls` - Run coverage.

## Rules

- Use the `Jido.Chat.Teams` module namespace.
- Keep live tests excluded by default with the `:live` tag.
- Do not commit `.env`, credentials, access tokens, or conversation references.
- Treat the Activity Protocol as the primary message path.
- Keep Microsoft Graph optional and do not use Graph as the primary send path.
- Validate a Bot Connector JWT before trusting its `serviceUrl`.
- Preserve the adapter boundary. Runtime routing, retries, and persistence belong in `jido_messaging`.

## Release Hygiene

- Do not modify `CHANGELOG.md`. Release notes come from Git history.
