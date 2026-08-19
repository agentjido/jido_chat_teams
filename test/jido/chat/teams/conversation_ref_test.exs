defmodule Jido.Chat.Teams.ConversationRefTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Teams.ConversationRef

  test "encodes and decodes all route data" do
    reference =
      ConversationRef.new(%{
        conversation_id: "19:thread@thread.tacv2",
        service_url: "https://smba.trafficmanager.net/amer/",
        tenant_id: "tenant-1",
        scope: :channel,
        team_id: "team-1",
        channel_id: "channel-1",
        bot_id: "28:bot",
        user_id: "user-1"
      })

    encoded = ConversationRef.encode(reference)

    assert String.starts_with?(encoded, "teamsref:v1:")
    assert {:ok, ^reference} = ConversationRef.decode(encoded)
    refute encoded =~ "app-password"
  end

  test "casts a plain conversation ID only when a service URL is present" do
    assert {:error, :missing_conversation_reference} = ConversationRef.cast("conversation-1")

    assert {:ok, reference} =
             ConversationRef.cast("conversation-1",
               service_url: "https://smba.trafficmanager.net/amer/",
               scope: :personal
             )

    assert reference.conversation_id == "conversation-1"
    assert reference.service_url == "https://smba.trafficmanager.net/amer"
    assert reference.scope == :personal
  end

  test "rejects invalid encoded data" do
    assert {:error, :invalid_conversation_reference} =
             ConversationRef.decode("teamsref:v1:not-base64")
  end
end
