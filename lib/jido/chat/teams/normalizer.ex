defmodule Jido.Chat.Teams.Normalizer do
  @moduledoc false

  alias Jido.Chat.{Delivery, Signal}
  alias Jido.Chat.Teams.{CardRenderer, ConversationRef}

  @file_download_content_type "application/vnd.microsoft.teams.file.download.info"

  @doc "Converts private Teams Activities to one validated public delivery."
  def normalize(client, input) do
    items = if is_list(input), do: input, else: [input]
    delivery_id = "teams:" <> digest({client.id, items})
    context = %{client: client, delivery_id: delivery_id}

    with {:ok, facts} <-
           items
           |> Enum.with_index()
           |> Enum.reduce_while({:ok, []}, &reduce_item(context, &1, &2)) do
      Delivery.new(client, delivery_id, facts)
    end
  rescue
    _ -> Signal.Policy.error(:invalid_delivery)
  end

  defp reduce_item(context, {item, index}, {:ok, facts}) do
    kind = provider_kind(item)
    item_id = "teams:#{kind}:" <> digest(item)

    case safe_map_item(context, kind, item, item_id) do
      {:ok, mapped} -> {:cont, {:ok, facts ++ List.wrap(mapped)}}
      {:error, reason} -> append_failure(context, item, index, kind, item_id, reason, facts)
    end
  end

  defp append_failure(context, item, index, kind, item_id, reason, facts) do
    data = %{
      "code" => failure_code(reason),
      "provider_kind" => kind,
      "item_index" => index,
      "room_id" => safe_room(item)
    }

    case fact(context, Signal.NormalizationFailed, item_id, data) do
      {:ok, failure} -> {:cont, {:ok, facts ++ [failure]}}
      error -> {:halt, error}
    end
  end

  defp failure_code(:unsupported), do: "unsupported_item"
  defp failure_code(_), do: "invalid_item"

  defp provider_kind(item) when is_map(item),
    do: to_string(value(item, :type) || "invalid")

  defp provider_kind(_), do: "invalid"

  defp safe_map_item(context, kind, payload, item_id) do
    map_item(context, kind, payload, item_id)
  rescue
    _ -> {:error, :invalid}
  end

  defp map_item(c, "message", payload, item_id),
    do: message_received(c, payload, item_id)

  defp map_item(c, "messageUpdate", payload, item_id),
    do: message_updated(c, payload, item_id)

  defp map_item(c, "messageDelete", payload, item_id),
    do: message_deleted(c, payload, item_id)

  defp map_item(c, "messageReaction", payload, item_id),
    do: reactions(c, payload, item_id)

  defp map_item(c, "invoke", payload, item_id) do
    if value(payload, :name) == "application/search" do
      options_requested(c, payload, item_id)
    else
      action_received(c, payload, item_id)
    end
  end

  defp map_item(_, _, _, _), do: {:error, :unsupported}

  defp message_received(c, payload, item_id) do
    with {:ok, reference} <- conversation_reference(payload) do
      mentions = mentions(c.client, payload)
      text = clean_text(value(payload, :text), mentions)

      fact(c, Signal.MessageReceived, item_id, %{
        "room_id" => ConversationRef.encode(reference),
        "message_id" => identifier(value(payload, :id)),
        "sender" => actor(c.client, payload),
        "text" => text || "",
        "thread_id" => thread_id(reference),
        "reply_to_id" => identifier(value(payload, :replyToId)),
        "media" => media(c.client, payload),
        "mentions" => Enum.map(mentions, & &1.id),
        "mentioned" => Enum.any?(mentions, & &1.self?),
        "timestamp" => timestamp(payload),
        "conversation_kind" => conversation_kind(reference.scope),
        "conversation_name" => conversation_name(payload)
      })
    end
  end

  defp message_updated(c, payload, item_id) do
    with {:ok, reference} <- conversation_reference(payload) do
      fact(c, Signal.MessageUpdated, item_id, %{
        "room_id" => ConversationRef.encode(reference),
        "message_id" => identifier(value(payload, :id)),
        "sender" => optional_actor(c.client, payload),
        "text" => value(payload, :text),
        "thread_id" => thread_id(reference),
        "media" => media(c.client, payload),
        "timestamp" => timestamp(payload)
      })
    end
  end

  defp message_deleted(c, payload, item_id) do
    with {:ok, reference} <- conversation_reference(payload) do
      fact(c, Signal.MessageDeleted, item_id, %{
        "room_id" => ConversationRef.encode(reference),
        "message_id" => identifier(value(payload, :id)),
        "actor_id" => actor_id(payload),
        "thread_id" => thread_id(reference),
        "timestamp" => timestamp(payload)
      })
    end
  end

  defp reactions(c, payload, item_id) do
    with {:ok, reference} <- conversation_reference(payload) do
      room_id = ConversationRef.encode(reference)
      actor_id = actor_id(payload)
      message_id = identifier(value(payload, :replyToId) || value(payload, :id))

      events =
        Enum.map(List.wrap(value(payload, :reactionsAdded)), &{Signal.ReactionAdded, &1}) ++
          Enum.map(List.wrap(value(payload, :reactionsRemoved)), &{Signal.ReactionRemoved, &1})

      events
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn event, result ->
        append_reaction(c, reference, room_id, actor_id, message_id, item_id, event, result)
      end)
      |> case do
        {:ok, []} -> {:error, :invalid}
        result -> result
      end
    end
  end

  defp append_reaction(
         context,
         reference,
         room_id,
         actor_id,
         message_id,
         item_id,
         {{definition, reaction}, index},
         {:ok, facts}
       ) do
    data = %{
      "room_id" => room_id,
      "message_id" => message_id,
      "actor_id" => actor_id,
      "reaction" => identifier(value(reaction, :type)),
      "thread_id" => thread_id(reference)
    }

    case fact(context, definition, "#{item_id}:#{index}", data) do
      {:ok, value} -> {:cont, {:ok, facts ++ [value]}}
      error -> {:halt, error}
    end
  end

  defp action_received(c, payload, item_id) do
    with {:ok, reference} <- conversation_reference(payload) do
      raw_value = value(payload, :value) || %{}
      action = value(raw_value, :action) || raw_value

      action_id =
        identifier(value(action, :verb) || value(action, :action_id) || value(payload, :name))

      action_value = public_action_value(action)

      fact(c, Signal.ActionReceived, item_id, %{
        "room_id" => ConversationRef.encode(reference),
        "interaction_id" => identifier(value(payload, :id)),
        "action_id" => action_id,
        "actor_id" => actor_id(payload),
        "message_id" => identifier(value(payload, :replyToId) || value(payload, :id)),
        "thread_id" => thread_id(reference),
        "value" => action_value,
        "values" => %{action_id => action_value}
      })
    end
  end

  defp options_requested(c, payload, item_id) do
    with {:ok, reference} <- conversation_reference(payload) do
      request = value(payload, :value) || %{}
      query_options = value(request, :queryOptions) || %{}

      fact(c, Signal.OptionsRequested, item_id, %{
        "room_id" => ConversationRef.encode(reference),
        "interaction_id" => identifier(value(payload, :id)),
        "action_id" => identifier(value(request, :dataset) || value(request, :action_id)),
        "query" => identifier(value(request, :queryText)) || "",
        "actor_id" => actor_id(payload),
        "limit" => positive_integer(value(query_options, :top))
      })
    end
  end

  defp fact(context, definition, item_id, data) do
    room_id = data["room_id"]

    subject =
      if is_binary(room_id) and room_id != "",
        do: Signal.Identity.conversation_subject(context.client.id, room_id)

    data =
      data
      |> compact()
      |> Map.merge(%{"item_id" => item_id, "delivery_id" => context.delivery_id})

    Signal.Policy.new(definition, data,
      id: item_id,
      source: context.client.source,
      subject: subject
    )
  end

  defp conversation_reference(payload) do
    conversation = value(payload, :conversation) || %{}
    channel_data = value(payload, :channelData) || %{}
    tenant = value(channel_data, :tenant) || %{}
    team = value(channel_data, :team) || %{}
    channel = value(channel_data, :channel) || %{}
    recipient = value(payload, :recipient) || %{}
    from = value(payload, :from) || %{}

    ConversationRef.cast(%{
      conversation_id: value(conversation, :id),
      service_url: value(payload, :serviceUrl),
      tenant_id: value(tenant, :id),
      scope: activity_scope(conversation, team, channel),
      team_id: value(team, :id),
      channel_id: value(channel, :id),
      bot_id: value(recipient, :id),
      user_id: value(from, :aadObjectId) || value(from, :id)
    })
  end

  defp safe_room(payload) when is_map(payload) do
    case conversation_reference(payload) do
      {:ok, reference} -> ConversationRef.encode(reference)
      _ -> nil
    end
  end

  defp safe_room(_), do: nil

  defp activity_scope(_conversation, team, channel)
       when map_size(team) > 0 or map_size(channel) > 0,
       do: :channel

  defp activity_scope(conversation, _team, _channel) do
    case value(conversation, :conversationType) do
      "personal" -> :personal
      "groupChat" -> :group_chat
      "channel" -> :channel
      _ -> nil
    end
  end

  defp actor(client, payload) do
    from = value(payload, :from) || %{}
    id = identifier(value(from, :aadObjectId) || value(from, :id))
    recipient_id = id(value(payload, :recipient), :id)

    %{
      "id" => id,
      "username" => present(value(from, :name)),
      "display_name" => present(value(from, :name)),
      "is_bot" => id == recipient_id,
      "is_self" => id in [client.config[:bot_id], recipient_id]
    }
    |> compact()
  end

  defp optional_actor(client, payload) do
    case actor(client, payload) do
      %{"id" => id} = value when is_binary(id) and id != "" -> value
      _ -> nil
    end
  end

  defp actor_id(payload) do
    from = value(payload, :from) || %{}
    identifier(value(from, :aadObjectId) || value(from, :id))
  end

  defp mentions(client, payload) do
    recipient_id = id(value(payload, :recipient), :id)

    payload
    |> value(:entities)
    |> List.wrap()
    |> Enum.flat_map(&mention(&1, client.config[:bot_id], recipient_id))
  end

  defp mention(entity, bot_id, recipient_id) do
    if value(entity, :type) == "mention" do
      entity
      |> value(:mentioned)
      |> mention_value(value(entity, :text), bot_id, recipient_id)
    else
      []
    end
  end

  defp mention_value(mentioned, text, bot_id, recipient_id) when is_map(mentioned) do
    case identifier(value(mentioned, :id)) do
      nil -> []
      id -> [%{id: id, text: text, self?: id in [bot_id, recipient_id]}]
    end
  end

  defp mention_value(_, _, _, _), do: []

  defp clean_text(text, mentions) when is_binary(text) do
    mentions
    |> Enum.filter(& &1.self?)
    |> Enum.reduce(text, fn mention, result ->
      if is_binary(mention.text), do: String.replace(result, mention.text, ""), else: result
    end)
    |> String.trim()
  end

  defp clean_text(_, _), do: nil

  defp media(client, payload) do
    payload
    |> value(:attachments)
    |> List.wrap()
    |> Enum.flat_map(fn attachment ->
      type = normalize_media_type(value(attachment, :contentType))
      url = safe_media_url(value(attachment, :contentUrl))

      if downloadable_media?(url, type) do
        [
          %{
            "kind" => media_kind(type, value(attachment, :name), url),
            "name" => present(value(attachment, :name)),
            "media_type" => type,
            "resource_ref" => %{"client_id" => client.id, "kind" => "media", "id" => url}
          }
          |> compact()
        ]
      else
        []
      end
    end)
  end

  defp media_kind(type, _name, _url) when is_binary(type) do
    cond do
      String.starts_with?(String.downcase(type), "image/") -> "image"
      String.starts_with?(String.downcase(type), "audio/") -> "audio"
      String.starts_with?(String.downcase(type), "video/") -> "video"
      true -> "file"
    end
  end

  defp media_kind(_, name, url) do
    extension = Path.extname(URI.parse(name || url).path || "") |> String.downcase()

    cond do
      extension in ~w(.png .jpg .jpeg .gif .webp .svg .bmp) -> "image"
      extension in ~w(.mp3 .wav .ogg .m4a .aac .flac) -> "audio"
      extension in ~w(.mp4 .mov .avi .webm .mkv) -> "video"
      true -> "file"
    end
  end

  defp downloadable_media?(url, type),
    do: is_binary(url) and type not in [CardRenderer.content_type(), @file_download_content_type]

  defp normalize_media_type(value) when is_binary(value) do
    value
    |> String.split(";", parts: 2)
    |> List.first()
    |> present()
    |> case do
      nil -> nil
      type -> type |> String.trim() |> String.downcase()
    end
  end

  defp normalize_media_type(_), do: nil

  defp safe_media_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) ->
        present(value)

      _ ->
        nil
    end
  end

  defp safe_media_url(_), do: nil

  defp public_action_value(value) when is_binary(value), do: value

  defp public_action_value(value) when is_map(value) do
    case value(value, :value) do
      nested when is_binary(nested) -> nested
      _ -> Jason.encode!(string_keys(value))
    end
  end

  defp public_action_value(_), do: nil

  defp string_keys(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json_value(value)} end)

  defp json_value(value) when is_map(value), do: string_keys(value)
  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value), do: value

  defp timestamp(payload),
    do: present(value(payload, :timestamp)) || present(value(payload, :localTimestamp))

  defp thread_id(%ConversationRef{scope: :channel, conversation_id: id}), do: id
  defp thread_id(_), do: nil
  defp conversation_kind(:personal), do: "direct"
  defp conversation_kind(:group_chat), do: "group"
  defp conversation_kind(:channel), do: "channel"
  defp conversation_kind(_), do: "unknown"

  defp conversation_name(payload) do
    channel_data = value(payload, :channelData) || %{}
    channel = value(channel_data, :channel) || %{}
    team = value(channel_data, :team) || %{}
    present(value(channel, :name)) || present(value(team, :name))
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_), do: nil

  defp value(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_, _), do: nil
  defp id(map, key), do: identifier(value(map, key))
  defp identifier(nil), do: nil
  defp identifier(value), do: to_string(value)

  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp present(_), do: nil
  defp compact(map), do: Map.reject(map, fn {_, value} -> is_nil(value) end)

  defp digest(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.url_encode64(padding: false)
end
