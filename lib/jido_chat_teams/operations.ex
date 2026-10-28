defmodule Jido.Chat.Teams.Operations do
  @moduledoc false
  alias Jido.Chat.{Client, Signal}
  alias Jido.Chat.Teams.{Adapter, ConversationRef}

  def invoke(operation, %Client{adapter: Adapter} = client, request, opts) do
    call(operation, client, request.data, Keyword.merge(Client.options(client), opts))
  end

  def invoke(_, _, _, _), do: {:error, {:not_attempted, :unsupported}}

  defp call(:send_message, client, data, opts) do
    with {:ok, reference} <- ConversationRef.cast(data["room_id"], opts),
         activity <- activity(data["text"]),
         {:ok, raw} <- send(client, reference, data["reply_to_id"], activity, opts) do
      message(raw, data["room_id"], data["text"], "sent", data["reply_to_id"])
    end
  end

  defp call(:edit_message, client, data, opts) do
    with {:ok, reference} <- ConversationRef.cast(data["room_id"], opts),
         {:ok, raw} <-
           client.transport.update_activity(
             reference,
             data["message_id"],
             activity(data["text"]),
             opts
           ) do
      message(raw, data["room_id"], data["text"], "updated", data["message_id"])
    end
  end

  defp call(:delete_message, client, data, opts) do
    with {:ok, reference} <- ConversationRef.cast(data["room_id"], opts),
         {:ok, _} <- client.transport.delete_activity(reference, data["message_id"], opts) do
      {:ok, %{"acknowledged" => true}}
    end
  end

  defp call(:start_typing, client, data, opts) do
    with {:ok, reference} <- ConversationRef.cast(data["room_id"], opts),
         {:ok, _} <- client.transport.send_activity(reference, %{"type" => "typing"}, opts) do
      {:ok, %{"acknowledged" => true}}
    end
  end

  defp call(:fetch_metadata, _client, data, opts) do
    with {:ok, reference} <- ConversationRef.cast(data["room_id"], opts) do
      title = reference.channel_id || reference.team_id

      {:ok,
       %{
         "id" => reference.conversation_id,
         "room_id" => data["room_id"],
         "kind" => "conversation"
       }
       |> optional("title", title)}
    end
  end

  defp call(_, _, _, _), do: {:error, {:not_attempted, :unsupported}}

  defp send(client, reference, reply_to_id, activity, opts) when is_binary(reply_to_id),
    do: client.transport.reply_to_activity(reference, reply_to_id, activity, opts)

  defp send(client, reference, _, activity, opts),
    do: client.transport.send_activity(reference, activity, opts)

  defp activity(text), do: %{"type" => "message", "text" => text, "textFormat" => "plain"}

  defp message(raw, room_id, text, status, fallback_id) when is_map(raw) do
    result = %{
      "id" => identifier(raw["id"] || fallback_id),
      "room_id" => room_id,
      "text" => text,
      "status" => status
    }

    case Zoi.parse(Signal.Schemas.result(:message), result) do
      {:ok, checked} -> {:ok, checked}
      _ -> {:error, :invalid_provider_result}
    end
  end

  defp identifier(nil), do: nil
  defp identifier(value), do: to_string(value)
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
end
