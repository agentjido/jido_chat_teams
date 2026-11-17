# LLM Usage Rules for Jido Chat Teams

`jido_chat_teams` adapts Microsoft Teams Activity Protocol messages to the
`Jido.Chat.Adapter` contract.

## Working Rules

- Use Bot Connector activities for live message delivery.
- Keep Microsoft Graph optional for history and metadata.
- Validate inbound JWTs before any event enters the runtime.
- Build immutable `Jido.Chat.Client` values with explicit private credentials.
- Use request Signals and core Jido Chat Actions for outbound work.
- Normalize provider input with `Jido.Chat.normalize/2`.
- Let the host own webhook HTTP, response deadlines, and provider retry policy.
- Keep raw Activities, signed URLs, and credentials out of public Signals.
- Keep live tests tagged `:live` and disabled by default.
- Do not commit secrets, access tokens, or captured conversation references.
- Keep managed room runtime and durable storage in Jido Chat core.
- Do not restore V2 event structs or direct adapter send APIs.
