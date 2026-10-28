defmodule Jido.Chat.Teams.LiveIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :live
  @run_live System.get_env("RUN_LIVE_TEAMS_TESTS") in ["1", "true", "TRUE", "yes", "on"]

  if not @run_live do
    @moduletag skip: "set RUN_LIVE_TEAMS_TESTS=true to run live Teams tests"
  end

  if @run_live and
       Enum.any?(
         ~w(MICROSOFT_APP_ID MICROSOFT_APP_PASSWORD TEAMS_TEST_CONVERSATION_REF),
         &(System.get_env(&1) in [nil, ""])
       ) do
    raise "live Teams tests require MICROSOFT_APP_ID, MICROSOFT_APP_PASSWORD, and TEAMS_TEST_CONVERSATION_REF"
  end

  test "sends, edits, types, and deletes one live Teams activity" do
    app_id = System.fetch_env!("MICROSOFT_APP_ID")
    password = System.fetch_env!("MICROSOFT_APP_PASSWORD")
    room = System.fetch_env!("TEAMS_TEST_CONVERSATION_REF")

    client =
      Jido.Chat.Client.new!(Jido.Chat.Teams.Adapter,
        id: "teams-live",
        credentials: %{app_id: app_id, app_password: password}
      )

    text = "jido teams live #{System.system_time(:millisecond)}"
    assert {:ok, sent} = Jido.Chat.send_text(client, room, text)
    id = sent.data["result"]["id"]
    assert {:ok, _} = Jido.Chat.start_typing(client, room)
    assert {:ok, _} = Jido.Chat.edit_message(client, room, id, text <> " edited")
    assert {:ok, _} = Jido.Chat.delete_message(client, room, id)
  end
end
