# LLM Usage Rules for Jido Chat Teams

`jido_chat_teams` adapts Microsoft Teams Activity Protocol messages to the
`Jido.Chat.Adapter` contract.

## Working Rules

- Use Bot Connector activities for live message delivery.
- Keep Microsoft Graph optional for history and metadata.
- Validate inbound JWTs before any event enters the runtime.
- Keep live tests tagged `:live` and disabled by default.
- Do not commit secrets, access tokens, or captured conversation references.
- Keep runtime supervision, queues, and delivery retries in `jido_messaging`.
