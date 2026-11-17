defmodule Jido.Chat.Teams.LiveIntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.Chat
  alias Jido.Chat.Client
  alias Jido.Chat.Teams.{Adapter, ConversationRef}

  @run_live System.get_env("RUN_LIVE_TEAMS_TESTS") == "true"
  @app_id System.get_env("MICROSOFT_APP_ID")
  @app_password System.get_env("MICROSOFT_APP_PASSWORD")
  @app_tenant_id System.get_env("MICROSOFT_APP_TENANT_ID")
  @conversation_ref System.get_env("TEAMS_TEST_CONVERSATION_REF")

  @moduletag :live
  @moduletag :teams_live

  if not @run_live do
    @moduletag skip: "set RUN_LIVE_TEAMS_TESTS=true to run live Microsoft Teams tests"
  end

  if @run_live and Enum.any?([@app_id, @app_password, @conversation_ref], &(&1 in [nil, ""])) do
    @moduletag skip:
                 "set MICROSOFT_APP_ID, MICROSOFT_APP_PASSWORD, and TEAMS_TEST_CONVERSATION_REF"
  end

  setup_all do
    assert {:ok, _reference} = ConversationRef.decode(@conversation_ref || "")

    credentials =
      %{app_id: @app_id, app_password: @app_password}
      |> maybe_put(:app_tenant_id, @app_tenant_id)

    client = Client.new!(Adapter, id: "teams-live", credentials: credentials)
    {:ok, client: client, room_id: @conversation_ref}
  end

  test "sends, edits, types, and deletes a live Teams Activity", ctx do
    text = "jido teams live #{System.system_time(:millisecond)}"

    assert {:ok, sent} = Chat.send_text(ctx.client, ctx.room_id, text)
    message_id = sent.data["result"]["id"]
    assert is_binary(message_id)

    on_exit(fn -> Chat.delete_message(ctx.client, ctx.room_id, message_id) end)

    assert {:ok, _} = Chat.start_typing(ctx.client, ctx.room_id)

    assert {:ok, _} =
             Chat.edit_message(ctx.client, ctx.room_id, message_id, text <> " edited")

    assert {:ok, _} = Chat.delete_message(ctx.client, ctx.room_id, message_id)
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
