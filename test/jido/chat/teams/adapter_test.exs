defmodule Jido.Chat.Teams.AdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{
    ActionEvent,
    OptionsLoadError,
    OptionsLoadEvent,
    OptionsLoadResult,
    PostPayload,
    ReactionEvent,
    WebhookRequest
  }

  alias Jido.Chat.Teams.ConversationRef

  defmodule FakeTransport do
    @behaviour Jido.Chat.Teams.Transport

    @impl true
    def send_activity(reference, activity, opts) do
      send(opts[:test_pid], {:send_activity, reference, activity})
      {:ok, %{"id" => "activity-sent"}}
    end

    @impl true
    def reply_to_activity(reference, activity_id, activity, opts) do
      send(opts[:test_pid], {:reply_to_activity, reference, activity_id, activity})
      {:ok, %{"id" => "activity-reply"}}
    end

    @impl true
    def update_activity(reference, activity_id, activity, opts) do
      send(opts[:test_pid], {:update_activity, reference, activity_id, activity})
      {:ok, %{"id" => activity_id}}
    end

    @impl true
    def delete_activity(reference, activity_id, opts) do
      send(opts[:test_pid], {:delete_activity, reference, activity_id})
      {:ok, true}
    end
  end

  test "declares a valid Jido.Chat capability matrix" do
    assert :ok = Jido.Chat.Adapter.validate_capabilities(Jido.Chat.Teams.Adapter)

    capabilities = Jido.Chat.Teams.Adapter.capabilities()
    assert capabilities.card_charts == :fallback
    assert capabilities.card_tables == :native
    assert capabilities.modal_date_input == :native
    assert capabilities.modal_number_input == :fallback
    assert capabilities.external_select == :native
    assert capabilities.options_load == :native
    assert capabilities.link_action_ids == :native
  end

  test "normalizes a channel message and preserves a delivery reference" do
    assert {:ok, incoming} = Jido.Chat.Teams.Adapter.transform_incoming(channel_activity())

    assert incoming.external_room_id == "channel-1"
    assert incoming.external_user_id == "aad-user-1"
    assert incoming.external_message_id == "activity-1"
    assert incoming.external_thread_id == "19:thread@thread.tacv2"
    assert incoming.chat_type == :channel
    assert incoming.chat_title == "General"
    assert incoming.text == "hello from Teams"
    assert incoming.was_mentioned
    assert [%{user_id: "28:bot", is_self: true}] = incoming.mentions

    assert {:ok, reference} = ConversationRef.decode(incoming.delivery_external_room_id)
    assert reference.conversation_id == "19:thread@thread.tacv2"
    assert reference.service_url == "https://smba.trafficmanager.net/amer"
    assert reference.tenant_id == "tenant-1"
    assert reference.team_id == "team-1"
    assert reference.channel_id == "channel-1"
    assert reference.scope == :channel
  end

  test "normalizes a personal chat" do
    activity =
      channel_activity()
      |> Map.put("conversation", %{"id" => "personal-1", "conversationType" => "personal"})
      |> Map.put("channelData", %{"tenant" => %{"id" => "tenant-1"}})

    assert {:ok, incoming} = Jido.Chat.Teams.Adapter.transform_incoming(activity)
    assert incoming.external_room_id == "personal-1"
    assert incoming.external_thread_id == nil
    assert incoming.chat_type == :private
    assert incoming.channel_meta.is_dm
  end

  test "normalizes attachments when contentType is missing" do
    activity =
      Map.put(channel_activity(), "attachments", [
        %{
          "contentType" => " APPLICATION/VND.MICROSOFT.CARD.ADAPTIVE ",
          "content" => %{"type" => "AdaptiveCard"}
        },
        %{
          "name" => "explicit.png",
          "contentType" => "image/png",
          "contentUrl" => "https://teams.example.test/files/explicit"
        },
        %{
          "name" => "fallback.png",
          "contentUrl" => "https://teams.example.test/files/fallback"
        },
        %{
          "name" => "archive.unknown",
          "contentType" => " ",
          "contentUrl" => "https://teams.example.test/files/unknown"
        },
        %{
          "name" => " ",
          "contentUrl" => "https://teams.example.test/files/photo.PNG?token=signed"
        },
        %{
          "name" => "misleading.png",
          "contentType" => " application/pdf; charset=binary ",
          "contentUrl" => "https://teams.example.test/files/misleading"
        }
      ])

    assert {:ok, incoming} = Jido.Chat.Teams.Adapter.transform_incoming(activity)
    assert [explicit, fallback, unknown, signed_url, misleading] = incoming.media

    assert explicit.kind == :image
    assert explicit.media_type == "image/png"

    assert fallback.kind == :image
    assert fallback.filename == "fallback.png"
    assert fallback.media_type == nil

    assert unknown.kind == :file
    assert unknown.media_type == nil

    assert signed_url.kind == :image
    assert signed_url.filename == nil
    assert signed_url.media_type == nil

    assert misleading.kind == :file
    assert misleading.media_type == "application/pdf"
  end

  test "rejects unsupported activity types" do
    assert {:error, {:unsupported_activity_type, "conversationUpdate"}} =
             Jido.Chat.Teams.Adapter.transform_incoming(%{"type" => "conversationUpdate"})
  end

  test "sends, replies, edits, deletes, and starts typing" do
    reference = conversation_ref()
    opts = [transport: FakeTransport, test_pid: self()]

    assert {:ok, sent} = Jido.Chat.Teams.Adapter.send_message(reference, "hello", opts)
    assert sent.external_message_id == "activity-sent"

    assert_received {:send_activity, ^reference,
                     %{"type" => "message", "text" => "hello", "textFormat" => "markdown"}}

    assert {:ok, reply} =
             Jido.Chat.Teams.Adapter.send_message(
               ConversationRef.encode(reference),
               "reply",
               Keyword.put(opts, :reply_to_id, "parent-1")
             )

    assert reply.external_message_id == "activity-reply"

    assert_received {:reply_to_activity, ^reference, "parent-1",
                     %{"type" => "message", "text" => "reply", "textFormat" => "markdown"}}

    assert {:ok, edited} =
             Jido.Chat.Teams.Adapter.edit_message(reference, "activity-1", "edited", opts)

    assert edited.external_message_id == "activity-1"
    assert_received {:update_activity, ^reference, "activity-1", %{"text" => "edited"}}

    assert :ok = Jido.Chat.Teams.Adapter.start_typing(reference, opts)
    assert_received {:send_activity, ^reference, %{"type" => "typing"}}

    assert :ok = Jido.Chat.Teams.Adapter.delete_message(reference, "activity-1", opts)
    assert_received {:delete_activity, ^reference, "activity-1"}
  end

  test "posts a canonical card as an Adaptive Card" do
    reference = conversation_ref()

    payload =
      PostPayload.new(%{
        kind: :card,
        text: "Build result",
        card: %{
          title: "Build result",
          summary: "The build passed.",
          components: [%{kind: :button, id: "details", label: "Details", value: "42"}]
        }
      })

    assert {:ok, response} =
             Jido.Chat.Teams.Adapter.post_message(reference, payload,
               transport: FakeTransport,
               test_pid: self()
             )

    assert response.external_message_id == "activity-sent"

    assert_received {:send_activity, ^reference,
                     %{
                       "attachments" => [
                         %{
                           "contentType" => "application/vnd.microsoft.card.adaptive",
                           "content" => %{
                             "type" => "AdaptiveCard",
                             "body" => [_title, _summary, %{"type" => "ActionSet"}]
                           }
                         }
                       ]
                     }}
  end

  test "parses reaction and invoke activities into Jido.Chat events" do
    reaction_request =
      WebhookRequest.new(%{
        adapter_name: :teams,
        payload: %{
          "type" => "messageReaction",
          "id" => "reaction-1",
          "replyToId" => "activity-1",
          "conversation" => %{"id" => "conversation-1"},
          "from" => %{"id" => "user-1", "name" => "Alice"},
          "reactionsAdded" => [%{"type" => "like"}]
        }
      })

    assert {:ok, reaction_envelope} = Jido.Chat.Teams.Adapter.parse_event(reaction_request)

    assert %ReactionEvent{emoji: "like", added: true, message_id: "activity-1"} =
             reaction_envelope.payload

    invoke_request =
      WebhookRequest.new(%{
        adapter_name: :teams,
        payload: %{
          "type" => "invoke",
          "id" => "invoke-1",
          "name" => "adaptiveCard/action",
          "conversation" => %{"id" => "conversation-1"},
          "from" => %{"id" => "user-1", "name" => "Alice"},
          "value" => %{"action" => %{"verb" => "approve", "value" => "42"}}
        }
      })

    assert {:ok, action_envelope} = Jido.Chat.Teams.Adapter.parse_event(invoke_request)
    assert %ActionEvent{action_id: "approve", value: "42"} = action_envelope.payload
  end

  test "parses Teams dynamic-search invokes into normalized options-load events" do
    request =
      WebhookRequest.new(%{
        adapter_name: :teams,
        payload: %{
          "type" => "invoke",
          "name" => "application/search",
          "id" => "invoke-search-1",
          "replyToId" => "activity-1",
          "conversation" => %{"id" => "conversation-1"},
          "from" => %{"id" => "user-1", "name" => "Alice"},
          "value" => %{
            "dataset" => "assignee",
            "queryText" => "ad",
            "queryOptions" => %{"top" => 12, "skip" => 3},
            "timeoutMs" => 750,
            "data" => %{"team" => "core"}
          }
        }
      })

    assert {:ok, envelope} = Jido.Chat.Teams.Adapter.parse_event(request)
    assert envelope.event_type == :options_load

    assert %OptionsLoadEvent{
             action_id: "assignee",
             query: "ad",
             limit: 12,
             timeout_ms: 750,
             channel_id: "conversation-1",
             message_id: "activity-1"
           } = envelope.payload

    assert envelope.payload.metadata == %{associated_inputs: %{"team" => "core"}, skip: 3}

    malformed = put_in(request.payload["value"], %{"queryText" => "ad"})
    assert {:error, :missing_options_dataset} = Jido.Chat.Teams.Adapter.parse_event(malformed)
  end

  test "loads and formats dynamic options with Teams limits" do
    event = OptionsLoadEvent.new(%{action_id: "assignee", query: "ad", timeout_ms: 500})

    loader = fn ^event, _opts ->
      {:ok, %{options: [%{label: "Ada", value: "user:ada"}]}}
    end

    assert {:ok, %OptionsLoadResult{} = result} =
             Jido.Chat.Teams.Adapter.load_options(event, options_loader: loader)

    assert {:ok, %OptionsLoadResult{}} =
             Jido.Chat.Adapter.load_options(Jido.Chat.Teams.Adapter, event,
               options_loader: loader
             )

    response = Jido.Chat.Teams.Adapter.format_options_load_response({:ok, result})
    assert response.status == 200

    assert response.body == %{
             "type" => "application/vnd.microsoft.search.searchResponse",
             "value" => %{
               "results" => [%{"title" => "Ada", "value" => "user:ada"}]
             }
           }

    oversized_loader = fn _event, _opts ->
      {:ok,
       %{
         options: for(index <- 1..16, do: %{label: "Option #{index}", value: "value:#{index}"})
       }}
    end

    assert {:error, %OptionsLoadError{code: "teams_option_limit", retryable: false}} =
             Jido.Chat.Teams.Adapter.load_options(event, options_loader: oversized_loader)
  end

  test "normalizes missing loaders, groups, loader errors, and timeouts" do
    event = OptionsLoadEvent.new(%{action_id: "assignee", timeout_ms: 20})

    assert {:error, %OptionsLoadError{code: "options_loader_unavailable"}} =
             Jido.Chat.Teams.Adapter.load_options(event)

    group_loader = fn _event, _opts ->
      {:ok,
       %{
         option_groups: [
           %{label: "Teams", options: [%{label: "Core", value: "team:core"}]}
         ]
       }}
    end

    assert {:error, %OptionsLoadError{code: "teams_option_groups_unsupported"}} =
             Jido.Chat.Teams.Adapter.load_options(event, options_loader: group_loader)

    error_loader = fn _event, _opts -> {:error, :upstream_unavailable} end

    assert {:error, %OptionsLoadError{code: "options_loader_error"}} =
             Jido.Chat.Teams.Adapter.load_options(event, options_loader: error_loader)

    crashing_loader = fn _event, _opts -> raise "upstream crashed" end

    assert {:error, %OptionsLoadError{code: "options_loader_error"}} =
             Jido.Chat.Teams.Adapter.load_options(event, options_loader: crashing_loader)

    explicit_timeout_loader = fn _event, _opts -> {:error, :timeout} end

    assert {:error, %OptionsLoadError{kind: :timeout, timeout_ms: 20}} =
             Jido.Chat.Teams.Adapter.load_options(event,
               options_loader: explicit_timeout_loader
             )

    timeout_loader = fn _event, _opts ->
      Process.sleep(100)
      {:ok, %{options: []}}
    end

    assert {:error, %OptionsLoadError{kind: :timeout, timeout_ms: 20}} =
             Jido.Chat.Teams.Adapter.load_options(event, options_loader: timeout_loader)
  end

  test "uses standard, adapter, event, and default options timeout precedence" do
    timeout_loader = fn _event, _opts -> {:error, :timeout} end
    event = OptionsLoadEvent.new(%{action_id: "assignee", timeout_ms: 30})

    assert {:error, %OptionsLoadError{kind: :timeout, timeout_ms: 10}} =
             Jido.Chat.Teams.Adapter.load_options(event,
               options_loader: timeout_loader,
               timeout_ms: 10,
               options_timeout_ms: 20
             )

    assert {:error, %OptionsLoadError{kind: :timeout, timeout_ms: 20}} =
             Jido.Chat.Teams.Adapter.load_options(event,
               options_loader: timeout_loader,
               options_timeout_ms: 20
             )

    assert {:error, %OptionsLoadError{kind: :timeout, timeout_ms: 30}} =
             Jido.Chat.Teams.Adapter.load_options(event, options_loader: timeout_loader)

    event_without_timeout = OptionsLoadEvent.new(%{action_id: "assignee"})

    assert {:error, %OptionsLoadError{kind: :timeout, timeout_ms: 3_000}} =
             Jido.Chat.Teams.Adapter.load_options(event_without_timeout,
               options_loader: timeout_loader
             )
  end

  test "returns a typed timeout when the options loader exceeds the selected timeout" do
    event = OptionsLoadEvent.new(%{action_id: "assignee", timeout_ms: 100})

    timeout_loader = fn _event, _opts ->
      Process.sleep(100)
      {:ok, %{options: []}}
    end

    assert {:error,
            %OptionsLoadError{
              kind: :timeout,
              code: "options_load_timeout",
              retryable: true,
              timeout_ms: 10
            }} =
             Jido.Chat.Teams.Adapter.load_options(event,
               options_loader: timeout_loader,
               timeout_ms: 10
             )
  end

  test "uses an injected webhook verifier" do
    request = WebhookRequest.new(%{adapter_name: :teams, payload: channel_activity()})
    verifier = fn ^request, _opts -> :ok end

    assert :ok = Jido.Chat.Teams.Adapter.verify_webhook(request, verifier: verifier)
  end

  defp conversation_ref do
    ConversationRef.new(%{
      conversation_id: "19:thread@thread.tacv2",
      service_url: "https://smba.trafficmanager.net/amer",
      tenant_id: "tenant-1",
      scope: :channel,
      team_id: "team-1",
      channel_id: "channel-1"
    })
  end

  defp channel_activity do
    %{
      "type" => "message",
      "id" => "activity-1",
      "timestamp" => "2026-08-19T12:00:00Z",
      "serviceUrl" => "https://smba.trafficmanager.net/amer/",
      "conversation" => %{
        "id" => "19:thread@thread.tacv2",
        "conversationType" => "channel"
      },
      "from" => %{"id" => "29:user", "aadObjectId" => "aad-user-1", "name" => "Alice"},
      "recipient" => %{"id" => "28:bot", "name" => "Jido"},
      "text" => "<at>Jido</at> hello from Teams",
      "entities" => [
        %{
          "type" => "mention",
          "mentioned" => %{"id" => "28:bot", "name" => "Jido"},
          "text" => "<at>Jido</at>"
        }
      ],
      "channelData" => %{
        "tenant" => %{"id" => "tenant-1"},
        "team" => %{"id" => "team-1", "name" => "Jido"},
        "channel" => %{"id" => "channel-1", "name" => "General"}
      }
    }
  end
end
