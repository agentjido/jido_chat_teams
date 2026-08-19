defmodule Jido.Chat.Teams.AdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{ActionEvent, PostPayload, ReactionEvent, WebhookRequest}
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
