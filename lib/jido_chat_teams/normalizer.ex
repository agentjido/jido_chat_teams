defmodule Jido.Chat.Teams.Normalizer do
  @moduledoc false
  alias Jido.Chat.{Client, Delivery}
  alias Jido.Chat.Signal.{Identity, MessageReceived, MessageUpdated, NormalizationFailed, Policy}
  alias Jido.Chat.Teams.ConversationRef

  def normalize(%Client{} = client, input) when is_map(input) or is_list(input) do
    items = if is_list(input), do: input, else: [input]
    delivery_id = "teams:" <> digest({client.id, items})

    with {:ok, signals} <- map_items(client, delivery_id, items),
         do: Delivery.new(client, delivery_id, signals)
  rescue
    _ -> Policy.error(:invalid_delivery)
  catch
    _, _ -> Policy.error(:invalid_delivery)
  end

  def normalize(_, _), do: Policy.error(:invalid_delivery)

  defp map_items(client, delivery_id, items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case map_item(client, delivery_id, item, index) do
        {:ok, signal} -> {:cont, {:ok, acc ++ [signal]}}
        error -> {:halt, error}
      end
    end)
  end

  defp map_item(client, delivery_id, activity, index) when is_map(activity) do
    type = value(activity, "type")

    if type in ["message", "messageUpdate"] do
      with {:ok, reference} <- reference(activity),
           room <- ConversationRef.encode(reference),
           id when is_binary(id) and id != "" <- identifier(value(activity, "id")),
           sender when is_binary(sender) and sender != "" <- sender_id(activity) do
        definition = if type == "messageUpdate", do: MessageUpdated, else: MessageReceived

        data =
          %{
            "item_id" => "teams:item:" <> digest(activity),
            "delivery_id" => delivery_id,
            "room_id" => room,
            "message_id" => id,
            "sender" =>
              %{"id" => sender} |> optional("display_name", get_in(activity, ["from", "name"])),
            "text" => value(activity, "text") || ""
          }
          |> optional("reply_to_id", identifier(value(activity, "replyToId")))
          |> optional(
            "timestamp",
            value(activity, "timestamp") || value(activity, "localTimestamp")
          )
          |> received_fields(definition, reference)

        signal(client, definition, room, data)
      else
        _ -> failure(client, delivery_id, activity, index, nil, "invalid_item")
      end
    else
      failure(client, delivery_id, activity, index, nil, "unsupported_item")
    end
  end

  defp map_item(client, delivery_id, item, index),
    do: failure(client, delivery_id, item, index, nil, "invalid_item")

  defp received_fields(data, MessageReceived, reference) do
    Map.put(data, "conversation_kind", conversation_kind(reference.scope))
  end

  defp received_fields(data, _, _), do: data

  defp reference(activity) do
    channel = value(activity, "channelData") || %{}
    conversation = value(activity, "conversation") || %{}

    ConversationRef.cast(%{
      conversation_id: value(conversation, "id"),
      service_url: value(activity, "serviceUrl"),
      tenant_id: get_in(channel, ["tenant", "id"]),
      team_id: get_in(channel, ["team", "id"]),
      channel_id: get_in(channel, ["channel", "id"]),
      scope: value(conversation, "conversationType"),
      bot_id: get_in(activity, ["recipient", "id"]),
      user_id: sender_id(activity)
    })
  end

  defp failure(client, delivery_id, item, index, room, code) do
    data =
      %{
        "item_id" => "teams:item:" <> digest(item),
        "delivery_id" => delivery_id,
        "code" => code,
        "item_index" => index,
        "provider_kind" => "bot_activity"
      }
      |> optional("room_id", room)

    signal(client, NormalizationFailed, room, data)
  end

  defp signal(client, definition, room, data) do
    subject = if is_binary(room), do: Identity.conversation_subject(client.id, room)
    definition.new(data, source: client.source, subject: subject)
  end

  defp conversation_kind(:personal), do: "direct"
  defp conversation_kind(:group_chat), do: "group"
  defp conversation_kind(:channel), do: "channel"
  defp conversation_kind(_), do: "unknown"

  defp sender_id(activity) do
    from = value(activity, "from")
    value(from, "aadObjectId") || value(from, "id")
  end

  defp identifier(nil), do: nil
  defp identifier(value), do: to_string(value)

  defp value(map, key) when is_map(map) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {atom, item} when is_atom(atom) -> if Atom.to_string(atom) == key, do: item
        _ -> nil
      end)
  end

  defp value(_, _), do: nil
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)

  defp digest(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
    |> Base.url_encode64(padding: false)
  end
end
