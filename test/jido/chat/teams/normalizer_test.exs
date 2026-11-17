defmodule Jido.Chat.Teams.NormalizerTest do
  use ExUnit.Case, async: true

  alias Jido.Chat
  alias Jido.Chat.Client
  alias Jido.Chat.Teams.{Adapter, ConversationRef}
  alias Jido.Signal.Codec

  defp client do
    Client.new!(Adapter,
      id: "teams-normalizer",
      credentials: %{app_id: "app-1", app_password: "private-secret"},
      config: [bot_id: "28:bot"]
    )
  end

  defp activity(type, overrides) do
    Map.merge(
      %{
        "type" => type,
        "id" => "activity-1",
        "timestamp" => "2026-08-19T12:00:00Z",
        "serviceUrl" => "https://smba.trafficmanager.net/amer/",
        "conversation" => %{
          "id" => "19:thread@thread.tacv2",
          "conversationType" => "channel"
        },
        "from" => %{"id" => "29:user", "aadObjectId" => "aad-user-1", "name" => "Alice"},
        "recipient" => %{"id" => "28:bot", "name" => "Jido"},
        "channelData" => %{
          "tenant" => %{"id" => "tenant-1"},
          "team" => %{"id" => "team-1", "name" => "Jido"},
          "channel" => %{"id" => "channel-1", "name" => "General"}
        }
      },
      overrides
    )
  end

  test "message facts are stable, client scoped, and contain no private data" do
    payload =
      activity("message", %{
        "text" => "<at>Jido</at> hello from Teams",
        "entities" => [
          %{
            "type" => "mention",
            "mentioned" => %{"id" => "28:bot", "name" => "Jido"},
            "text" => "<at>Jido</at>"
          }
        ],
        "attachments" => [
          %{
            "name" => "image.png",
            "contentType" => "image/png",
            "contentUrl" => "https://smba.trafficmanager.net/amer/v3/attachments/1/views/original"
          }
        ]
      })

    assert {:ok, first} = Chat.normalize(client(), payload)
    assert {:ok, second} = Chat.normalize(client(), payload)
    assert first.id == second.id

    assert Enum.map(first.signals, &{&1.id, &1.data}) ==
             Enum.map(second.signals, &{&1.id, &1.data})

    [signal] = first.signals
    assert signal.type == "jido.chat.message.received"
    assert signal.data["text"] == "hello from Teams"
    assert signal.data["mentions"] == ["28:bot"]
    assert signal.data["mentioned"]
    assert signal.data["sender"]["id"] == "aad-user-1"
    assert signal.data["conversation_kind"] == "channel"
    assert signal.data["conversation_name"] == "General"

    assert {:ok, reference} = ConversationRef.decode(signal.data["room_id"])
    assert reference.channel_id == "channel-1"

    [media] = signal.data["media"]
    assert media["kind"] == "image"
    assert media["resource_ref"]["client_id"] == "teams-normalizer"

    encoded = Jason.encode!(Codec.to_map(signal))
    refute encoded =~ "private-secret"
  end

  test "signed and pre-authenticated attachment URLs do not enter public Signals" do
    payload =
      activity("message", %{
        "text" => "files",
        "attachments" => [
          %{
            "name" => "signed.png",
            "contentType" => "image/png",
            "contentUrl" => "https://files.example.test/signed.png?token=private"
          },
          %{
            "name" => "report.pdf",
            "contentType" => "application/vnd.microsoft.teams.file.download.info",
            "contentUrl" => "https://contoso.sharepoint.com/report.pdf",
            "content" => %{
              "downloadUrl" => "https://contoso.sharepoint.com/report.pdf?tempauth=private"
            }
          }
        ]
      })

    assert {:ok, %{signals: [signal]}} = Chat.normalize(client(), payload)
    assert signal.data["media"] == []
    refute inspect(signal) =~ "tempauth"
    refute inspect(signal) =~ "token=private"
  end

  test "updates, deletes, and added and removed reactions map to core facts" do
    inputs = [
      activity("messageUpdate", %{"id" => "message-1", "text" => "updated"}),
      activity("messageDelete", %{"id" => "message-2"}),
      activity("messageReaction", %{
        "id" => "reaction-1",
        "replyToId" => "message-1",
        "reactionsAdded" => [%{"type" => "like"}],
        "reactionsRemoved" => [%{"type" => "heart"}]
      })
    ]

    assert {:ok, delivery} = Chat.normalize(client(), inputs)

    assert Enum.map(delivery.signals, & &1.type) == [
             "jido.chat.message.updated",
             "jido.chat.message.deleted",
             "jido.chat.reaction.added",
             "jido.chat.reaction.removed"
           ]

    assert Enum.at(delivery.signals, 0).data["text"] == "updated"
    assert Enum.at(delivery.signals, 1).data["message_id"] == "message-2"
    assert Enum.at(delivery.signals, 2).data["reaction"] == "like"
    assert Enum.at(delivery.signals, 3).data["reaction"] == "heart"
  end

  test "Adaptive Card actions and dynamic option requests map to public facts" do
    action =
      activity("invoke", %{
        "id" => "invoke-1",
        "name" => "adaptiveCard/action",
        "value" => %{"action" => %{"verb" => "approve", "value" => "yes"}}
      })

    options =
      activity("invoke", %{
        "id" => "invoke-2",
        "name" => "application/search",
        "value" => %{
          "dataset" => "assignee",
          "queryText" => "ad",
          "queryOptions" => %{"top" => 12}
        }
      })

    assert {:ok, %{signals: [action_fact, options_fact]}} =
             Chat.normalize(client(), [action, options])

    assert action_fact.type == "jido.chat.action.received"
    assert action_fact.data["action_id"] == "approve"
    assert action_fact.data["values"] == %{"approve" => "yes"}
    assert options_fact.type == "jido.chat.options.requested"
    assert options_fact.data["action_id"] == "assignee"
    assert options_fact.data["query"] == "ad"
    assert options_fact.data["limit"] == 12
  end

  test "invalid and unsupported items become bounded failure facts" do
    for input <- [
          nil,
          %{},
          %{"type" => "conversationUpdate"},
          activity("message", %{"id" => nil})
        ] do
      assert {:ok, %{signals: [failure]}} = Chat.normalize(client(), input)
      assert failure.type == "jido.chat.normalization.failed"
    end

    assert {:ok, %{signals: []}} = Chat.normalize(client(), [])
    assert {:error, _} = Chat.normalize(client(), List.duplicate(nil, 21))
  end
end
