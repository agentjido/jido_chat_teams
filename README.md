# Jido Chat Teams

`jido_chat_teams` is an early Microsoft Teams adapter for the `Jido.Chat` ecosystem.
It uses the Microsoft Bot Connector Activity Protocol. It does not require a Node.js
or .NET sidecar.

This package is a spike. Its public API can change before the first stable release.

## Spike scope

The spike includes these functions:

- Receive channel, group chat, and personal chat activities.
- Verify inbound Bot Connector JWTs.
- Remove the bot mention from inbound text.
- Preserve a versioned conversation delivery reference.
- Send, reply to, edit, and delete text messages.
- Send typing activities.
- Render `Jido.Chat.Card` data as Adaptive Cards.
- Parse message reaction and Adaptive Card invoke activities.
- Run deterministic protocol and security tests with no Microsoft account.
- Run an optional live suite after you add credentials and a conversation reference.

The spike does not include files, Graph history, proactive conversation creation,
ephemeral messages, or modal windows. Reaction activities are parsed, but the
adapter does not add or remove reactions. Microsoft Graph is not in the normal send
path.

## Install

Add the package to the dependencies in your Mix project:

```elixir
def deps do
  [
    {:jido_chat_teams, "~> 0.1.0"}
  ]
end
```

For local development in this workspace, use this path dependency:

```elixir
{:jido_chat_teams, path: "../jido_chat_teams"}
```

## Receive an activity

Your HTTPS endpoint must pass the request headers and decoded JSON activity to the
adapter. Verify the request before you parse it.

```elixir
alias Jido.Chat.Teams.Adapter
alias Jido.Chat.WebhookRequest

request =
  WebhookRequest.new(%{
    adapter_name: :teams,
    headers: request_headers,
    payload: activity,
    raw: raw_body
  })

with :ok <- Adapter.verify_webhook(request, app_id: microsoft_app_id),
     {:ok, event} <- Adapter.parse_event(request) do
  {:ok, event}
end
```

JWT verification checks the signature, algorithm, issuer, audience, time claims,
and exact `serviceUrl`. The adapter gets current signing keys from Microsoft and
caches them. You can inject `:jwks`, `:now`, and `:req` in deterministic tests.

Do not accept a `serviceUrl` from an unverified activity. The outbound transport
also limits service URLs to known Microsoft service hosts by default.

## Send an activity

A reply after the webhook request needs the conversation ID and the verified
service URL. The adapter puts both values in `Incoming.delivery_external_room_id`
as a versioned `teamsref:v1:` value. Store and use this value for outbound delivery.
It has route data, but it has no secret.

```elixir
opts = [
  app_id: System.fetch_env!("MICROSOFT_APP_ID"),
  app_password: System.fetch_env!("MICROSOFT_APP_PASSWORD")
]

{:ok, response} =
  Jido.Chat.Teams.Adapter.send_message(delivery_external_room_id, "Hello from Jido", opts)
```

You can also put the credentials in a `:credentials` map. This shape works with
`Jido.Messaging.BridgeConfig`:

```elixir
credentials = %{
  app_id: System.fetch_env!("MICROSOFT_APP_ID"),
  app_password: System.fetch_env!("MICROSOFT_APP_PASSWORD")
}
```

The token cache gets a Bot Connector access token when it is necessary. You can
pass `access_token: "..."` for a short test.

## Adaptive Cards

Use a canonical `Jido.Chat.PostPayload` with `kind: :card`:

```elixir
payload =
  Jido.Chat.PostPayload.new(%{
    kind: :card,
    text: "Build result",
    card: %{
      title: "Build result",
      summary: "The build passed.",
      components: [
        %{kind: :button, id: "details", label: "Details", value: "42"}
      ]
    }
  })

Jido.Chat.Teams.Adapter.post_message(delivery_external_room_id, payload, opts)
```

The adapter also accepts a raw Adaptive Card map with `"type" => "AdaptiveCard"`.

## Microsoft app setup

The [`appPackage/manifest.json`](appPackage/manifest.json) file is a development
template. Before you make the app package:

1. Replace `${TEAMS_APP_ID}` with the Teams app ID.
2. Replace `${MICROSOFT_APP_ID}` with the Microsoft Entra application ID.
3. Add valid `appPackage/color.png` and `appPackage/outline.png` icon files.
4. Set the Azure Bot messaging endpoint to your public HTTPS activity endpoint.
5. Add the app to the test tenant and team.
6. Send one message to the bot and capture the verified inbound conversation data.

Make the test conversation reference from that verified activity:

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

IO.puts(Jido.Chat.Teams.ConversationRef.encode(reference))
```

## Tests

The normal suite has no live network calls:

```shell
mix test
mix quality
```

The live suite is disabled by default. Copy `.env.example` to `.env.test`, and set:

```text
RUN_LIVE_TEAMS_TESTS=true
MICROSOFT_APP_ID=...
MICROSOFT_APP_PASSWORD=...
TEAMS_TEST_CONVERSATION_REF=teamsref:v1:...
TEAMS_TEST_REPLY_TO_ID=...
```

`TEAMS_TEST_REPLY_TO_ID` is optional. Run the live suite with this command:

```shell
mix test --include live test/jido/chat/team/live_integration_test.exs
```

The suite sends visible messages to the selected test conversation. It edits and
deletes the test data. Use a dedicated tenant, team, and channel.

## Known limits

- A bot normally receives channel messages only when users mention it. Broader
  access needs the applicable Teams permissions and tenant consent.
- Private and shared channels have Microsoft platform limits. Test these scopes
  separately before you use them in production.
- The adapter returns `{:error, {:rate_limited, milliseconds}}` for HTTP 429. The
  caller must wait for this interval before it tries again.
- Long work must return an HTTP success response quickly and do later delivery with
  the stored conversation reference.
