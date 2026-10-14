# Jido Chat Teams



`jido_chat_teams` provides the `Jido.Chat.Teams.Adapter` adapter for the public Chat Signal contract.

## Release status

This branch proposes version 0.2. It changes the public communication API.
Use the immutable PR source commits for review and tests. The new Hex releases
are not yet published. Production requires Chat 2.0 and compatible upstream
Signal releases. The dependency helpers keep source pins in development and test.

## Typed operations

The application supplies private binding options and a provider room ID:

```elixir
{:ok, binding} = Jido.Chat.bind(Jido.Chat.Teams.Adapter, private_binding_options)
request = Jido.Chat.Signal.SendMessage.new!(%{
  "request_id" => "request-1",
  "room_id" => provider_room_id,
  "text" => "Hello"
})
{:ok, result} = Jido.Chat.execute(binding, request)
```

The result is an OperationCompleted or OperationFailed signal. Repeating an
admitted request uses its saved result. Private tokens, clients and resources
stay outside signal data. Unsupported operations return a defined typed result.

## Inbound delivery

Normalize one complete verified provider input unit with the configured binding:

```elixir
{:ok, delivery} = Jido.Chat.normalize_event(binding, verified_provider_input)
{:ok, observations} = MyApp.Messaging.accept_delivery(delivery)
```

The Messaging instance owns runtime acceptance. Deliveries retain ordered facts
and explicit item failures. Membership evidence does not create grants or start
message handlers. A rejected listener sink follows the provider checkpoint rule.
Configure protocol version 1 before starting provider listeners.

## Operation support

Native: `send_message`, `post_message`, `edit_message`, `delete_message`, `start_typing`, `load_options`.

Fallback: `fetch_metadata`, `fetch_thread`, `fetch_subject`, `stream`.

All other operations are explicitly unsupported. See the frozen [adapter matrix](https://github.com/agentjido/jido_chat/blob/codex/public-signal-v3/docs/migration/adapter-matrix.json).

## Provider setup

Teams uses the Activity Protocol for messages. Verify the Bot Connector JWT before using serviceUrl. Microsoft Graph remains optional. Conversation references and access tokens remain private. Adaptive Cards and options use the declared typed operations.

## Checks and migration

Run `mix test` and `mix quality`. Live tests stay excluded by default. The fixed
provider fixtures do not need credentials or live traffic.

See the [migration guide](https://github.com/agentjido/jido_chat/blob/codex/public-signal-v3/docs/migration/MIGRATION_GUIDE.md)
for API mappings, the complete runnable local example, limits, release order and
rollback pins. Run `mix docs` to build this package's API documentation.
