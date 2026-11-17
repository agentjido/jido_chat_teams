# Architecture

The package has five main boundaries:

- `Jido.Chat.Teams.Adapter` declares capabilities, executes request Signals,
  and normalizes Microsoft Activities.
- The internal operations module converts core requests to Activity Protocol
  calls and canonical results.
- `Jido.Chat.Teams.Webhook` verifies host-owned HTTP input and builds plain
  invoke responses.
- `Jido.Chat.Teams.ConversationRef` keeps the verified conversation ID and
  service URL that later delivery needs.
- `Jido.Chat.Teams.CardRenderer` and `Jido.Chat.Teams.ModalRenderer` convert
  canonical UI data to Adaptive Cards.

`Jido.Chat.Client` contains the app ID, app password, optional tenant ID,
transport module, and private transport settings. Operations pass credentials
to the transport as explicit private values. The package does not read
application environment values.

The Activity Protocol is the main message path. Microsoft Graph is optional.
The host owns HTTP, response deadlines, and provider retry policy. Jido Chat
core owns Agent DSL integration, authorization, managed rooms, durable
declarations, membership, message history, and storage adapters.

The package starts no process. It owns no credential cache, room state, queue,
or message store. The JWT verifier caches only public Microsoft signing keys.
