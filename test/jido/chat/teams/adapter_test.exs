defmodule Jido.Chat.Teams.AdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{
    PostPayload,
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
    incoming = normalize(channel_activity())

    assert incoming.data["room_id"] == "channel-1"
    assert incoming.data["sender"]["id"] == "aad-user-1"
    assert incoming.data["message_id"] == "activity-1"
    assert incoming.data["thread_id"] == "19:thread@thread.tacv2"
    assert incoming.data["conversation_kind"] == "channel"
    assert incoming.data["conversation_name"] == "General"
    assert incoming.data["text"] == "hello from Teams"
    assert incoming.data["mentioned"]
    assert ["28:bot"] = incoming.data["mentions"]

    binding = Process.get(:teams_binding)
    assert [{_, ^binding, ref}] = :ets.lookup(binding.options[:reference_store], "channel-1")
    assert {:ok, %{reference: reference}} = Jido.Chat.resolve_resource(binding, ref)
    refute Jason.encode!(Jido.Signal.to_map(incoming)) =~ "smba.trafficmanager.net"
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

    incoming = normalize(activity)
    assert incoming.data["room_id"] == "personal-1"
    assert incoming.data["thread_id"] == nil
    assert incoming.data["conversation_kind"] == "direct"
    assert incoming.data["conversation_kind"] == "direct"
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

    incoming = normalize(activity)

    media =
      Enum.map(incoming.data["media"], fn item ->
        assert {:ok, media} =
                 Jido.Chat.resolve_resource(Process.get(:teams_binding), item["resource_ref"])

        media
      end)

    assert [explicit, fallback, unknown, signed_url, misleading] = media

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
    binding = native_binding()

    assert {:ok, %{signals: []}} =
             Jido.Chat.normalize_event(binding, %{"type" => "conversationUpdate"})

    assert {:ok, %{signals: [%{type: "jido.chat.normalization.failed"}]}} =
             Jido.Chat.normalize_event(binding, %{"type" => "unknown"})
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

    reaction = normalize(reaction_request.payload, false)

    assert reaction.type == "jido.chat.reaction.added"
    assert reaction.data["reaction"] == "like" and reaction.data["message_id"] == "activity-1"

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

    action = normalize(invoke_request.payload, false)
    assert action.type == "jido.chat.action.received"
    assert action.data["action_id"] == "approve" and action.data["value"] == "42"
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

    request = %{request | payload: Map.put(request.payload, "serviceUrl", "https://fixture.test")}
    binding = native_binding()
    assert {:ok, %{signals: [fact]}} = Jido.Chat.normalize_event(binding, request)
    assert fact.type == "jido.chat.options.requested"

    assert Map.take(fact.data, ["action_id", "query", "limit", "room_id", "interaction_id"]) ==
             %{
               "action_id" => "assignee",
               "query" => "ad",
               "limit" => 12,
               "room_id" => "conversation-1",
               "interaction_id" => "invoke-search-1"
             }

    assert [{_, ^binding, ref}] = :ets.lookup(binding.options[:reference_store], "conversation-1")
    assert {:ok, %{activity: private}} = Jido.Chat.resolve_resource(binding, ref)
    assert private["value"]["data"] == %{"team" => "core"}
    assert private["value"]["queryOptions"]["skip"] == 3
    assert private["value"]["timeoutMs"] == 750
    refute Map.has_key?(fact.data, "timeout_ms")
    malformed = put_in(request.payload["value"], %{"queryText" => "ad"})

    assert {:ok, %{signals: [%{type: "jido.chat.normalization.failed"}]}} =
             Jido.Chat.normalize_event(binding, malformed.payload)
  end

  test "loads and formats dynamic options with Teams limits" do
    event = options_query(%{action_id: "assignee", query: "ad", timeout_ms: 500})

    loader = fn ^event, _opts ->
      {:ok, %{options: [%{label: "Ada", value: "user:ada"}]}}
    end

    assert {:ok, %{options: _} = result} =
             load_options(event, options_loader: loader)

    assert {:ok, %{type: "jido.chat.operation.completed"}} =
             execute_options(event,
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

    assert {:error, %{code: "teams_option_limit", retryable: false}} =
             load_options(event, options_loader: oversized_loader)
  end

  test "normalizes missing loaders, groups, loader errors, and timeouts" do
    event = options_query(%{action_id: "assignee", timeout_ms: 20})

    assert {:error, %{code: "options_loader_unavailable"}} =
             load_options(event)

    group_loader = fn _event, _opts ->
      {:ok,
       %{
         option_groups: [
           %{label: "Teams", options: [%{label: "Core", value: "team:core"}]}
         ]
       }}
    end

    assert {:error, %{code: "teams_option_groups_unsupported"}} =
             load_options(event, options_loader: group_loader)

    error_loader = fn _event, _opts -> {:error, :upstream_unavailable} end

    assert {:error, %{code: "options_loader_error"}} =
             load_options(event, options_loader: error_loader)

    crashing_loader = fn _event, _opts -> raise "upstream crashed" end

    assert {:error, %{code: "options_loader_error"}} =
             load_options(event, options_loader: crashing_loader)

    explicit_timeout_loader = fn _event, _opts -> {:error, :timeout} end

    assert {:error, %{kind: :timeout, timeout_ms: 20}} =
             load_options(event,
               options_loader: explicit_timeout_loader
             )

    timeout_loader = fn _event, _opts ->
      Process.sleep(100)
      {:ok, %{options: []}}
    end

    assert {:error, %{kind: :timeout, timeout_ms: 20}} =
             load_options(event, options_loader: timeout_loader)
  end

  test "uses standard, adapter, event, and default options timeout precedence" do
    timeout_loader = fn _event, _opts -> {:error, :timeout} end
    event = options_query(%{action_id: "assignee", timeout_ms: 30})

    assert {:error, %{kind: :timeout, timeout_ms: 10}} =
             load_options(event,
               options_loader: timeout_loader,
               timeout_ms: 10,
               options_timeout_ms: 20
             )

    assert {:error, %{kind: :timeout, timeout_ms: 20}} =
             load_options(event,
               options_loader: timeout_loader,
               options_timeout_ms: 20
             )

    assert {:error, %{kind: :timeout, timeout_ms: 30}} =
             load_options(event, options_loader: timeout_loader)

    event_without_timeout = options_query(%{action_id: "assignee"})

    assert {:error, %{kind: :timeout, timeout_ms: 3_000}} =
             load_options(event_without_timeout,
               options_loader: timeout_loader
             )
  end

  test "returns a typed timeout when the options loader exceeds the selected timeout" do
    event = options_query(%{action_id: "assignee", timeout_ms: 100})

    timeout_loader = fn _event, _opts ->
      Process.sleep(100)
      {:ok, %{options: []}}
    end

    assert {:error,
            %{
              kind: :timeout,
              code: "options_load_timeout",
              retryable: true,
              timeout_ms: 10
            }} =
             load_options(event,
               options_loader: timeout_loader,
               timeout_ms: 10
             )
  end

  test "uses an injected webhook verifier" do
    request = WebhookRequest.new(%{adapter_name: :teams, payload: channel_activity()})
    verifier = fn ^request, _opts -> :ok end

    assert :ok = Jido.Chat.Teams.Adapter.verify_webhook(request, verifier: verifier)
  end

  defp native_binding do
    {:ok, binding} =
      Jido.Chat.bind(Jido.Chat.Teams.Adapter, id: "teams-test", verifier: fn _, _ -> :ok end)

    Process.put(:teams_binding, binding)
    binding
  end

  defp normalize(payload, verified \\ true) do
    input = if verified, do: WebhookRequest.new(%{payload: payload}), else: payload
    assert {:ok, %{signals: [fact]}} = Jido.Chat.normalize_event(native_binding(), input)
    fact
  end

  defp options_query(attrs) do
    Process.put(:event_timeout, attrs[:timeout_ms])

    data = %{
      "request_id" => "options-test",
      "interaction_id" => "invoke-1",
      "query" => attrs[:query] || "",
      "action_id" => attrs[:action_id]
    }

    Jido.Chat.Signal.LoadOptions.new!(data)
  end

  defp load_options(event, opts \\ []),
    do:
      Jido.Chat.Teams.Adapter.load_options(
        event,
        Keyword.put_new(opts, :event_timeout_ms, Process.get(:event_timeout))
      )

  defp execute_options(event, opts) do
    {:ok, binding} =
      Jido.Chat.bind(Jido.Chat.Teams.Adapter, Keyword.put(opts, :id, "options-binding"))

    Jido.Chat.execute(binding, event)
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
