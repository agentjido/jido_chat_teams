defmodule Jido.Chat.Teams.AdapterTest do
  use Jido.Chat.AdapterTestKit, adapter: Jido.Chat.Teams.Adapter

  alias Jido.Chat.Teams.{Adapter, ConversationRef}

  defmodule FakeTransport do
    @behaviour Jido.Chat.Teams.Transport
    def send_activity(_, _, _), do: {:ok, %{"id" => "a1"}}
    def reply_to_activity(_, _, _, _), do: {:ok, %{"id" => "a2"}}
    def update_activity(_, id, _, _), do: {:ok, %{"id" => id}}
    def delete_activity(_, _, _), do: {:ok, true}
  end

  setup do
    reference =
      ConversationRef.encode(%{
        conversation_id: "conversation-1",
        service_url: "https://smba.trafficmanager.net/amer",
        scope: :personal,
        user_id: "u1",
        bot_id: "b1"
      })

    %{
      client: Jido.Chat.Client.new!(Adapter, id: "teams-test", transport: FakeTransport),
      room: reference
    }
  end

  test "runs activity operations through public Chat Actions", %{client: client, room: room} do
    assert {:ok, sent} = Jido.Chat.send_text(client, room, "hello")
    assert sent.data["result"]["id"] == "a1"
    assert {:ok, edited} = Jido.Chat.edit_message(client, room, "a1", "edited")
    assert edited.data["result"]["id"] == "a1"
    assert {:ok, deleted} = Jido.Chat.delete_message(client, room, "a1")
    assert deleted.data["result"] == %{"acknowledged" => true}
  end

  test "normalizes Bot Connector activities into routable messages", %{client: client} do
    activity = %{
      "type" => "message",
      "id" => "a1",
      "serviceUrl" => "https://smba.trafficmanager.net/amer",
      "conversation" => %{"id" => "conversation-1", "conversationType" => "personal"},
      "from" => %{"id" => "u1", "name" => "User"},
      "recipient" => %{"id" => "b1"},
      "text" => "hello"
    }

    assert {:ok, first} = Jido.Chat.normalize(client, activity)
    assert {:ok, second} = Jido.Chat.normalize(client, activity)
    assert first.id == second.id

    assert Enum.map(first.signals, &{&1.type, &1.data}) ==
             Enum.map(second.signals, &{&1.type, &1.data})

    assert [signal] = first.signals
    assert signal.data["message_id"] == "a1"
    assert signal.data["conversation_kind"] == "direct"

    assert {:ok, %ConversationRef{conversation_id: "conversation-1"}} =
             ConversationRef.decode(signal.data["room_id"])
  end
end
