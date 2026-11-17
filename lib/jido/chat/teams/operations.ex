defmodule Jido.Chat.Teams.Operations do
  @moduledoc false

  alias Jido.Chat.{Client, Signal}
  alias Jido.Chat.Teams.{Adapter, CardRenderer, ConversationRef}

  @local_operations [:fetch_metadata, :fetch_thread, :fetch_subject, :load_options]
  @provider_operations [
    :stream_text,
    :send_message,
    :edit_message,
    :delete_message,
    :start_typing,
    :download_file
  ]
  @options_timeout_ms 3_000

  @doc false
  @spec invoke(atom(), Client.t(), Jido.Signal.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def invoke(operation, %Client{adapter: Adapter} = client, request, opts)
      when operation in @local_operations do
    call(operation, client, client.credentials, request.data, Keyword.merge(client.config, opts))
  end

  def invoke(
        operation,
        %Client{adapter: Adapter, credentials: credentials} = client,
        request,
        opts
      )
      when operation in @provider_operations and is_map(credentials) do
    if provider_credentials?(credentials) do
      call(operation, client, credentials, request.data, Keyword.merge(client.config, opts))
    else
      {:error, {:not_attempted, :missing_app_credentials}}
    end
  end

  def invoke(operation, %Client{adapter: Adapter}, _, _) when operation in @provider_operations,
    do: {:error, {:not_attempted, :missing_app_credentials}}

  def invoke(_, _, _, _), do: {:error, {:not_attempted, :unsupported}}

  defp call(:stream_text, client, credentials, data, opts) do
    case Jido.Chat.Adapter.render_stream(opts[:stream]) do
      text when is_binary(text) -> send_message(client, credentials, data, text, opts)
      _ -> {:error, :invalid_stream}
    end
  end

  defp call(:send_message, client, credentials, data, opts),
    do: send_message(client, credentials, data, data["text"], opts)

  defp call(:edit_message, client, credentials, data, opts) do
    with {:ok, reference} <- ConversationRef.cast(data["room_id"]),
         {:ok, activity} <- message_activity(data["text"], data),
         {:ok, raw} <-
           client.transport.update_activity(
             credentials,
             reference,
             data["message_id"],
             activity,
             opts
           ) do
      message(raw, data["room_id"], data["message_id"], data["text"], "updated")
    end
  end

  defp call(:delete_message, client, credentials, data, opts) do
    with {:ok, reference} <- ConversationRef.cast(data["room_id"]),
         {:ok, _} <-
           client.transport.delete_activity(
             credentials,
             reference,
             data["message_id"],
             opts
           ) do
      result(:acknowledgement, %{"acknowledged" => true})
    end
  end

  defp call(:start_typing, client, credentials, data, opts) do
    with {:ok, reference} <- ConversationRef.cast(data["room_id"]),
         {:ok, _} <-
           client.transport.send_activity(
             credentials,
             reference,
             %{"type" => "typing"},
             opts
           ) do
      result(:acknowledgement, %{"acknowledged" => true})
    end
  end

  defp call(:fetch_metadata, _client, _credentials, data, _opts) do
    with {:ok, reference} <- ConversationRef.cast(data["room_id"]) do
      result(:conversation, %{
        "id" => data["room_id"],
        "kind" => conversation_kind(reference.scope),
        "name" => reference.channel_id || reference.team_id
      })
    end
  end

  defp call(:fetch_thread, _client, _credentials, data, _opts) do
    with {:ok, reference} <- ConversationRef.cast(data["room_id"]) do
      result(:thread, %{
        "id" => data["thread_id"],
        "room_id" => data["room_id"],
        "parent_message_id" => nil,
        "delivery_room_ref" => reference.conversation_id
      })
    end
  end

  defp call(:fetch_subject, _client, _credentials, data, _opts) do
    with {:ok, reference} <- ConversationRef.cast(data["room_id"]) do
      result(:subject, %{
        "id" => data["room_id"],
        "room_id" => data["room_id"],
        "kind" => "conversation",
        "title" => reference.channel_id || reference.team_id
      })
    end
  end

  defp call(:download_file, client, credentials, data, opts) do
    reference = data["resource_ref"]

    with true <- reference["client_id"] == client.id,
         true <- reference["kind"] == "media",
         true <- public_media_reference?(reference["id"]),
         {:ok, bytes} when is_binary(bytes) <-
           client.transport.download_media(credentials, reference["id"], opts) do
      result(:resource, %{"content_base64" => Base.encode64(bytes)})
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_resource_reference}
    end
  end

  defp call(:load_options, _client, _credentials, data, opts) do
    with {:ok, loader} <- options_loader(opts),
         {:ok, value} <- invoke_loader(loader, data, opts),
         {:ok, options} <- canonical_options(value, data["limit"]) do
      result(:options, options)
    end
  end

  defp send_message(client, credentials, data, text, opts) do
    with {:ok, reference} <- ConversationRef.cast(data["room_id"]),
         {:ok, activity} <- message_activity(text, data),
         {:ok, raw} <- send_activity(client, credentials, reference, activity, data, opts) do
      message(raw, data["room_id"], nil, text, "sent")
    end
  end

  defp send_activity(client, credentials, reference, activity, data, opts) do
    case data["reply_to_id"] do
      id when is_binary(id) and id != "" ->
        client.transport.reply_to_activity(credentials, reference, id, activity, opts)

      _ ->
        client.transport.send_activity(credentials, reference, activity, opts)
    end
  end

  defp message_activity(text, data) when is_binary(text) do
    with {:ok, format} <- text_format(data["format"]) do
      activity = %{"type" => "message", "text" => text, "textFormat" => format}

      case keyboard_attachment(data["keyboard"]) do
        nil -> {:ok, activity}
        attachment -> {:ok, Map.put(activity, "attachments", [attachment])}
      end
    end
  end

  defp message_activity(_, _), do: {:error, :invalid_message}

  defp text_format(nil), do: {:ok, "markdown"}
  defp text_format("markdown"), do: {:ok, "markdown"}
  defp text_format("plain"), do: {:ok, "plain"}
  defp text_format("html"), do: {:error, {:not_attempted, :unsupported_format}}

  defp keyboard_attachment(%{"rows" => rows}) do
    actions =
      rows
      |> List.flatten()
      |> Enum.map(fn button ->
        case button do
          %{"url" => url} ->
            %{"type" => "Action.OpenUrl", "title" => button["text"], "url" => url}

          _ ->
            %{
              "type" => "Action.Submit",
              "title" => button["text"],
              "data" => %{"action_id" => button["value"], "value" => button["value"]}
            }
        end
      end)

    %{
      "contentType" => CardRenderer.content_type(),
      "content" => %{
        "$schema" => "https://adaptivecards.io/schemas/adaptive-card.json",
        "type" => "AdaptiveCard",
        "version" => "1.5",
        "body" => [],
        "actions" => actions
      }
    }
  end

  defp keyboard_attachment(_), do: nil

  defp message(raw, room_id, fallback_id, text, status) when is_map(raw) do
    result(:message, %{
      "id" => identifier(raw["id"] || raw["activityId"] || fallback_id),
      "room_id" => room_id,
      "text" => text,
      "status" => status
    })
  end

  defp message(_, _, _, _, _), do: {:error, :invalid_provider_result}

  defp options_loader(opts) do
    case opts[:options_loader] do
      loader when is_function(loader, 1) or is_function(loader, 2) ->
        {:ok, loader}

      {module, function, args} = loader
      when is_atom(module) and is_atom(function) and is_list(args) ->
        {:ok, loader}

      _ ->
        {:error, {:not_attempted, :missing_options_loader}}
    end
  end

  defp invoke_loader(loader, data, opts) do
    with {:ok, timeout} <- options_timeout(opts) do
      caller = self()
      reply_ref = make_ref()

      {pid, monitor_ref} =
        spawn_monitor(fn -> send(caller, {reply_ref, safe_loader(loader, data, opts)}) end)

      receive do
        {^reply_ref, result} ->
          Process.demonitor(monitor_ref, [:flush])
          normalize_loader(result)

        {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
          {:error, {:options_loader_failed, reason}}
      after
        timeout ->
          Process.exit(pid, :kill)
          receive do: ({:DOWN, ^monitor_ref, :process, ^pid, _} -> :ok)
          receive do: ({^reply_ref, _} -> :ok), after: (0 -> :ok)
          {:error, :options_timeout}
      end
    end
  end

  defp safe_loader(loader, data, opts) do
    cond do
      is_function(loader, 2) -> loader.(data, opts)
      is_function(loader, 1) -> loader.(data)
      true -> apply(elem(loader, 0), elem(loader, 1), [data, opts | elem(loader, 2)])
    end
  rescue
    error -> {:error, {:options_loader_failed, error}}
  catch
    kind, reason -> {:error, {:options_loader_failed, {kind, reason}}}
  end

  defp normalize_loader({:ok, value}), do: {:ok, value}
  defp normalize_loader({:error, _} = error), do: error
  defp normalize_loader(value), do: {:ok, value}

  defp options_timeout(opts) do
    case opts[:options_timeout_ms] || @options_timeout_ms do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      :infinity -> {:ok, :infinity}
      _ -> {:error, :invalid_options_timeout}
    end
  end

  defp canonical_options(%{"options" => options} = value, limit) when is_list(options) do
    options =
      if is_integer(limit),
        do: Enum.take(options, min(limit, CardRenderer.max_choices())),
        else: options

    if length(options) <= CardRenderer.max_choices() and value["option_groups"] in [nil, []] do
      {:ok,
       %{"options" => Enum.map(options, &option/1), "complete" => value["complete"] != false}}
    else
      {:error, :invalid_options_result}
    end
  rescue
    _ -> {:error, :invalid_options_result}
  end

  defp canonical_options(%{options: options} = value, limit) when is_list(options) do
    canonical_options(
      %{
        "options" => options,
        "option_groups" => value[:option_groups],
        "complete" => value[:complete]
      },
      limit
    )
  end

  defp canonical_options(options, limit) when is_list(options),
    do: canonical_options(%{"options" => options}, limit)

  defp canonical_options(_, _), do: {:error, :invalid_options_result}

  defp option(%{"label" => label, "value" => value} = option),
    do:
      Map.take(option, ["label", "value", "description", "url"])
      |> Map.merge(%{"label" => to_string(label), "value" => to_string(value)})

  defp option(%{label: label, value: value}),
    do: %{"label" => to_string(label), "value" => to_string(value)}

  defp option({label, value}), do: %{"label" => to_string(label), "value" => to_string(value)}

  defp result(kind, value) do
    case Zoi.parse(Signal.Schemas.result(kind), compact(value)) do
      {:ok, checked} -> {:ok, checked}
      _ -> {:error, :invalid_provider_result}
    end
  end

  defp provider_credentials?(credentials) do
    present?(credential(credentials, :app_id)) and
      present?(credential(credentials, :app_password))
  end

  defp credential(credentials, key),
    do: credentials[key] || credentials[Atom.to_string(key)]

  defp public_media_reference?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) ->
        true

      _ ->
        false
    end
  end

  defp public_media_reference?(_), do: false

  defp present?(value), do: is_binary(value) and value != ""
  defp identifier(nil), do: nil
  defp identifier(value), do: to_string(value)
  defp compact(map), do: Map.reject(map, fn {_, value} -> is_nil(value) end)
  defp conversation_kind(:personal), do: "direct"
  defp conversation_kind(:group_chat), do: "group"
  defp conversation_kind(:channel), do: "channel"
  defp conversation_kind(_), do: "unknown"
end
