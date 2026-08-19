defmodule Jido.Chat.Teams.LiveIntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.PostPayload
  alias Jido.Chat.Teams.{Adapter, ConversationRef}

  @run_live System.get_env("RUN_LIVE_TEAMS_TESTS") in ["1", "true", "TRUE", "yes", "on"]
  @app_id System.get_env("MICROSOFT_APP_ID")
  @app_password System.get_env("MICROSOFT_APP_PASSWORD")
  @conversation_ref System.get_env("TEAMS_TEST_CONVERSATION_REF")
  @reply_to_id System.get_env("TEAMS_TEST_REPLY_TO_ID")

  @moduletag :live
  @moduletag :teams_live

  if not @run_live do
    @moduletag skip: "set RUN_LIVE_TEAMS_TESTS=true to run live Microsoft Teams tests"
  end

  if @run_live and
       Enum.any?([@app_id, @app_password, @conversation_ref], &(&1 in [nil, ""])) do
    @moduletag skip:
                 "set MICROSOFT_APP_ID, MICROSOFT_APP_PASSWORD, and TEAMS_TEST_CONVERSATION_REF"
  end

  setup_all do
    assert {:ok, reference} = ConversationRef.decode(@conversation_ref || "")

    {:ok, reference: reference, opts: [app_id: @app_id, app_password: @app_password]}
  end

  test "sends, edits, types, and deletes a live Teams activity", ctx do
    text = "jido team live #{System.system_time(:millisecond)}"

    assert {:ok, sent} = Adapter.send_message(ctx.reference, text, ctx.opts)
    message_id = sent.external_message_id
    assert is_binary(message_id)

    on_exit(fn -> Adapter.delete_message(ctx.reference, message_id, ctx.opts) end)

    assert :ok = Adapter.start_typing(ctx.reference, ctx.opts)

    assert {:ok, edited} =
             Adapter.edit_message(ctx.reference, message_id, text <> " edited", ctx.opts)

    assert edited.external_message_id == message_id
    assert :ok = Adapter.delete_message(ctx.reference, message_id, ctx.opts)
  end

  test "sends and deletes a live Adaptive Card", ctx do
    payload =
      PostPayload.new(%{
        kind: :card,
        text: "Jido Teamss live card",
        card: %{
          title: "Jido Teamss live card",
          summary: "This card is from the opt-in integration suite.",
          components: [%{kind: :button, id: "live_test", label: "Test", value: "ok"}]
        }
      })

    assert {:ok, sent} = Adapter.post_message(ctx.reference, payload, ctx.opts)
    assert is_binary(sent.external_message_id)
    assert :ok = Adapter.delete_message(ctx.reference, sent.external_message_id, ctx.opts)
  end

  if @reply_to_id not in [nil, ""] do
    test "sends a reply when TEAMS_TEST_REPLY_TO_ID is present", ctx do
      assert {:ok, sent} =
               Adapter.send_message(
                 ctx.reference,
                 "jido team live reply #{System.system_time(:millisecond)}",
                 Keyword.put(ctx.opts, :reply_to_id, @reply_to_id)
               )

      assert is_binary(sent.external_message_id)
      assert :ok = Adapter.delete_message(ctx.reference, sent.external_message_id, ctx.opts)
    end
  end
end
