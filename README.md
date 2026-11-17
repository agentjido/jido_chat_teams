# Jido Chat Teams

`jido_chat_teams` is the Microsoft Teams adapter for Jido Chat V3. It uses the
Microsoft Bot Connector Activity Protocol. It does not need a Node.js or .NET
sidecar.

## V3 local integration

This worktree uses the sibling `../jido_chat` package. Select a released Hex
constraint only during later release work.

The adapter is stateless. A `Jido.Chat.Client` holds private credentials and
transport settings. Client construction starts no process and makes no request.

```elixir
client =
  Jido.Chat.Client.new!(Jido.Chat.Teams.Adapter,
    id: "teams/support",
    credentials: %{
      app_id: System.fetch_env!("MICROSOFT_APP_ID"),
      app_password: System.fetch_env!("MICROSOFT_APP_PASSWORD"),
      app_tenant_id: System.get_env("MICROSOFT_APP_TENANT_ID")
    }
  )
```

The optional tenant ID selects a single-tenant OAuth endpoint. Without it, the
transport uses the multi-tenant Bot Framework endpoint. The package does not
read application environment values. It does not keep a bearer-token cache.

## Agent connection

Use `Jido.Chat.Plugin` in the Agent and add the Teams connection to its `chat`
block. Environment references resolve when the Agent starts.

```elixir
connection :teams do
  client Jido.Chat.Teams.Adapter,
    id: "teams/support",
    credentials: %{
      app_id: env("MICROSOFT_APP_ID"),
      app_password: env("MICROSOFT_APP_PASSWORD"),
      app_tenant_id: env("MICROSOFT_APP_TENANT_ID")
    }

  commands [Jido.Chat.SendMessage]
end
```

Jido Chat core owns the Agent integration, authorization, managed rooms,
durable declarations, membership, history, and storage. This package owns only
Teams protocol behavior.

## Receive an Activity

The host owns the HTTPS endpoint and response deadline. Verify the request
before you normalize its Activity.

```elixir
with :ok <-
       Jido.Chat.Teams.Webhook.verify(client, activity, request_headers),
     {:ok, delivery} <- Jido.Chat.normalize(client, activity) do
  MyApp.accept(delivery.signals)
end
```

JWT verification checks the signature, algorithm, issuer, audience, time
claims, and exact `serviceUrl`. The verifier caches public Microsoft signing
keys. You can inject `:jwks`, `:now`, and `:req` in offline tests.

Do not accept a `serviceUrl` from an unverified Activity. The outbound
transport also restricts service URLs to known Microsoft hosts by default.

## Send an Activity

A later reply needs the conversation ID and the verified service URL. Incoming
message facts put both values in a versioned `teamsref:v1:` room ID. Store that
room ID with the message or room record.

```elixir
{:ok, completed} =
  Jido.Chat.send_text(client, teams_room_id, "Hello from Jido")

message_id = completed.data["result"]["id"]

{:ok, _} =
  Jido.Chat.send_text(client, teams_room_id, "A reply",
    reply_to_id: message_id
  )
```

The adapter also supports finite text streams, edits, deletes, typing notices,
conversation metadata, thread references, conversation subjects, media
downloads, and dynamic options. `Jido.Chat.capabilities/1` returns the exact
native and unsupported matrix.

## Media

Incoming facts expose only client-scoped media references for Bot Connector
attachments that have a safe URL. They do not expose pre-authenticated
`downloadUrl` values, OneDrive page references, or URLs with query credentials.
Download a reference through the same client:

```elixir
{:ok, completed} = Jido.Chat.download_file(client, media["resource_ref"])
bytes = Base.decode64!(completed.data["result"]["content_base64"])
```

Bot Connector attachment URLs get the bot bearer token only on trusted service
hosts. Pre-authenticated SharePoint URLs get no bearer token. Each redirect is
checked again. Set `max_media_bytes` in client config or execution options to
stop a large download.

## Adaptive Cards and options

The send API maps a canonical keyboard to Adaptive Card actions:

```elixir
keyboard = %{
  "rows" => [
    [
      %{"text" => "Approve", "value" => "approve"},
      %{"text" => "Docs", "url" => "https://example.com/docs"}
    ]
  ]
}

Jido.Chat.send_text(client, teams_room_id, "Review this", keyboard: keyboard)
```

`Jido.Chat.Teams.CardRenderer` and `Jido.Chat.Teams.ModalRenderer` remain public
pure renderers for the richer Adaptive Card features. An `application/search`
invoke normalizes to `jido.chat.options.requested`. Execute a `LoadOptions`
request with a private loader, then pass its result to
`Jido.Chat.Teams.Webhook.response/1`.

## Microsoft app setup

The [`appPackage/manifest.json`](appPackage/manifest.json) file is a development
template. Replace its app identifiers, add the two required icons, set the
Azure Bot messaging endpoint, and install the app in a test tenant.

Create a room reference only from a verified Activity:

```elixir
reference =
  Jido.Chat.Teams.ConversationRef.new(%{
    conversation_id: activity["conversation"]["id"],
    service_url: activity["serviceUrl"],
    tenant_id: activity["channelData"]["tenant"]["id"],
    scope: :channel,
    team_id: activity["channelData"]["team"]["id"],
    channel_id: activity["channelData"]["channel"]["id"]
  })

teams_room_id = Jido.Chat.Teams.ConversationRef.encode(reference)
```

## Validation

Default checks do not call Microsoft:

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix test.contracts
mix quality
mix coveralls
```

The optional live test requires a dedicated test conversation and explicit
environment credentials:

```sh
RUN_LIVE_TEAMS_TESTS=true \
MICROSOFT_APP_ID=... \
MICROSOFT_APP_PASSWORD=... \
TEAMS_TEST_CONVERSATION_REF=teamsref:v1:... \
mix test test/jido/chat/teams/live_integration_test.exs --include live
```

The live test sends, edits, and deletes visible messages. It is excluded by
default. See [architecture](docs/architecture.md) and
[validation](docs/validation.md).
