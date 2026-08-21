defmodule Jido.Chat.Teams.Adapter do
  @moduledoc """
  Microsoft Teams `Jido.Chat.Adapter` implementation.

  Live messages use Microsoft Bot Connector Activity Protocol endpoints. The
  adapter keeps Microsoft Graph out of the required message path.
  """

  use Jido.Chat.Adapter

  alias Jido.Chat.{
    ActionEvent,
    ChannelInfo,
    EventEnvelope,
    Incoming,
    OptionsLoadError,
    OptionsLoadEvent,
    OptionsLoadResult,
    PostPayload,
    ReactionEvent,
    Response,
    WebhookRequest,
    WebhookResponse
  }

  alias Jido.Chat.Teams.{CardRenderer, ConversationRef}
  alias Jido.Chat.Teams.Auth.JwtVerifier
  alias Jido.Chat.Teams.Transport.ReqClient

  @card_content_type "application/vnd.microsoft.card.adaptive"
  @default_options_timeout_ms 3_000
  @media_type_pattern ~r/^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/
  @media_kind_extensions %{
    ".aac" => :audio,
    ".avi" => :video,
    ".avif" => :image,
    ".bmp" => :image,
    ".flac" => :audio,
    ".gif" => :image,
    ".heic" => :image,
    ".heif" => :image,
    ".jpeg" => :image,
    ".jpg" => :image,
    ".m4a" => :audio,
    ".m4v" => :video,
    ".mkv" => :video,
    ".mov" => :video,
    ".mp3" => :audio,
    ".mp4" => :video,
    ".ogg" => :audio,
    ".png" => :image,
    ".svg" => :image,
    ".tif" => :image,
    ".tiff" => :image,
    ".wav" => :audio,
    ".webm" => :video,
    ".webp" => :image
  }

  @impl true
  def channel_type, do: :teams

  @impl true
  @spec capabilities() :: map()
  def capabilities do
    %{
      initialize: :fallback,
      shutdown: :fallback,
      send_message: :native,
      send_file: :unsupported,
      post_message: :native,
      edit_message: :native,
      delete_message: :native,
      start_typing: :native,
      fetch_metadata: :fallback,
      fetch_thread: :fallback,
      fetch_message: :unsupported,
      add_reaction: :unsupported,
      remove_reaction: :unsupported,
      post_ephemeral: :unsupported,
      open_dm: :unsupported,
      fetch_messages: :unsupported,
      fetch_channel_messages: :unsupported,
      list_threads: :unsupported,
      open_thread: :unsupported,
      post_channel_message: :unsupported,
      stream: :fallback,
      open_modal: :unsupported,
      load_options: :native,
      webhook: :native,
      verify_webhook: :native,
      parse_event: :native,
      format_webhook_response: :native,
      text: :native,
      markdown: :fallback,
      cards: :native,
      card_charts: :fallback,
      card_tables: :native,
      modal_date_input: :native,
      modal_number_input: :fallback,
      external_select: :native,
      options_load: :native,
      link_action_ids: :native,
      image: :unsupported,
      audio: :unsupported,
      video: :unsupported,
      file: :unsupported,
      multi_file: :unsupported,
      ephemeral: :unsupported,
      assistant_events: :unsupported
    }
  end

  @impl true
  def listener_child_specs(_bridge_id, _opts \\ []), do: {:ok, []}

  @impl true
  def transform_incoming(payload) when is_map(payload) do
    with type when type in ["message", "messageUpdate", "messageDelete"] <- value(payload, :type),
         {:ok, reference} <- conversation_reference(payload),
         room_id when is_binary(room_id) <- external_room_id(reference),
         message_id when is_binary(message_id) <- stringify(value(payload, :id)) do
      mentions = parse_mentions(payload)
      bot_id = value(value(payload, :recipient) || %{}, :id)
      was_mentioned = Enum.any?(mentions, &(&1.is_self == true))
      text = payload |> value(:text) |> clean_text(mentions)
      chat_type = chat_type(reference.scope)
      thread_id = if reference.scope == :channel, do: reference.conversation_id
      delivery_reference = ConversationRef.encode(reference)
      from = value(payload, :from) || %{}

      {:ok,
       Incoming.new(%{
         external_room_id: room_id,
         external_user_id: value(from, :aadObjectId) || value(from, :id),
         text: text,
         username: value(from, :name),
         display_name: value(from, :name),
         external_message_id: message_id,
         external_reply_to_id: stringify(value(payload, :replyToId)),
         external_thread_id: thread_id,
         delivery_external_room_id: delivery_reference,
         timestamp: value(payload, :timestamp) || value(payload, :localTimestamp),
         chat_type: chat_type,
         chat_title: chat_title(payload),
         was_mentioned: was_mentioned,
         mentions: mentions,
         media: extract_media(payload),
         channel_meta: %{
           adapter_name: :teams,
           external_room_id: room_id,
           external_thread_id: thread_id,
           delivery_external_room_id: delivery_reference,
           chat_type: chat_type,
           chat_title: chat_title(payload),
           is_dm: reference.scope == :personal,
           metadata: %{
             tenant_id: reference.tenant_id,
             team_id: reference.team_id,
             channel_id: reference.channel_id,
             conversation_id: reference.conversation_id,
             service_url: reference.service_url,
             bot_id: bot_id,
             activity_type: type
           }
         },
         raw: normalize_struct(payload),
         metadata: %{
           tenant_id: reference.tenant_id,
           team_id: reference.team_id,
           channel_id: reference.channel_id,
           conversation_id: reference.conversation_id,
           activity_type: type
         }
       })}
    else
      nil -> {:error, :invalid_activity}
      type when is_binary(type) -> {:error, {:unsupported_activity_type, type}}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_activity}
    end
  end

  def transform_incoming(_payload), do: {:error, :invalid_activity}

  @impl true
  def send_message(external_room_id, text, opts \\ []) when is_binary(text) do
    with {:ok, reference} <- ConversationRef.cast(external_room_id, opts),
         activity <- message_activity(text, opts),
         {:ok, result} <- send_activity(reference, activity, opts) do
      {:ok, response(reference, external_room_id, result, :sent)}
    end
  end

  @impl true
  def post_message(external_room_id, %PostPayload{} = payload, opts \\ []) do
    cond do
      PostPayload.upload_candidates(payload) != [] ->
        {:error, :attachments_unsupported}

      payload.kind == :card ->
        with {:ok, reference} <- ConversationRef.cast(external_room_id, opts),
             {:ok, card} <- render_card(payload.card || payload.raw),
             activity <- card_activity(card, payload, opts),
             {:ok, result} <- send_activity(reference, activity, opts) do
          {:ok, response(reference, external_room_id, result, :sent)}
        end

      payload.kind == :raw and is_map(payload.raw) ->
        with {:ok, reference} <- ConversationRef.cast(external_room_id, opts),
             {:ok, result} <- send_activity(reference, normalize_struct(payload.raw), opts) do
          {:ok, response(reference, external_room_id, result, :sent)}
        end

      true ->
        send_message(external_room_id, PostPayload.display_text(payload) || "", opts)
    end
  end

  @impl true
  def edit_message(external_room_id, message_id, text, opts \\ []) when is_binary(text) do
    with {:ok, reference} <- ConversationRef.cast(external_room_id, opts),
         {:ok, result} <-
           transport(opts).update_activity(
             reference,
             stringify(message_id),
             message_activity(text, opts),
             opts
           ) do
      {:ok, response(reference, external_room_id, put_result_id(result, message_id), :edited)}
    end
  end

  @impl true
  def delete_message(external_room_id, message_id, opts \\ []) do
    with {:ok, reference} <- ConversationRef.cast(external_room_id, opts),
         {:ok, _result} <-
           transport(opts).delete_activity(reference, stringify(message_id), opts) do
      :ok
    end
  end

  @impl true
  def start_typing(external_room_id, opts \\ []) do
    with {:ok, reference} <- ConversationRef.cast(external_room_id, opts),
         {:ok, _result} <- transport(opts).send_activity(reference, %{"type" => "typing"}, opts) do
      :ok
    end
  end

  @impl true
  def fetch_metadata(external_room_id, opts \\ []) do
    with {:ok, reference} <- ConversationRef.cast(external_room_id, opts) do
      {:ok,
       ChannelInfo.new(%{
         id: reference.channel_id || reference.conversation_id,
         is_dm: reference.scope == :personal,
         metadata: ConversationRef.to_map(reference)
       })}
    end
  end

  @impl true
  def fetch_thread(external_room_id, opts \\ []) do
    with {:ok, reference} <- ConversationRef.cast(external_room_id, opts) do
      {:ok,
       %{
         id: "team:#{reference.conversation_id}",
         adapter_name: :teams,
         adapter: __MODULE__,
         external_room_id: external_room_id,
         external_thread_id:
           opts[:external_thread_id] ||
             if(reference.scope == :channel, do: reference.conversation_id),
         is_dm: reference.scope == :personal,
         metadata: %{conversation_ref: ConversationRef.to_map(reference)}
       }}
    end
  end

  @impl true
  def load_options(%OptionsLoadEvent{} = event, opts \\ []) do
    timeout_ms =
      opts[:timeout_ms] || opts[:options_timeout_ms] || event.timeout_ms ||
        @default_options_timeout_ms

    with {:ok, loader} <- fetch_options_loader(opts),
         {:ok, result} <- call_options_loader(loader, event, opts, timeout_ms),
         {:ok, result} <- normalize_options_result(result, timeout_ms),
         :ok <- validate_options_result(result, event) do
      {:ok, result}
    end
  end

  @impl true
  def verify_webhook(%WebhookRequest{} = request, opts \\ []) do
    case Keyword.get(opts, :verifier, JwtVerifier) do
      verifier when is_atom(verifier) -> verifier.verify(request, opts)
      verifier when is_function(verifier, 2) -> verifier.(request, opts)
    end
  end

  @impl true
  def parse_event(%WebhookRequest{} = request, _opts \\ []) do
    payload = request.payload

    case {value(payload, :type), value(payload, :name)} do
      {type, _name} when type in ["message", "messageUpdate", "messageDelete"] ->
        with {:ok, incoming} <- transform_incoming(payload) do
          {:ok,
           EventEnvelope.new(%{
             id: stringify(value(payload, :id)) || Jido.Chat.ID.generate!(),
             adapter_name: :teams,
             event_type: :message,
             thread_id: incoming.external_thread_id,
             channel_id: stringify(incoming.external_room_id),
             message_id: stringify(incoming.external_message_id),
             payload: incoming,
             raw: normalize_struct(payload),
             metadata: %{activity_type: type}
           })}
        end

      {"messageReaction", _name} ->
        parse_reaction_event(payload)

      {"invoke", "application/search"} ->
        parse_options_load_event(payload)

      {"invoke", _name} ->
        parse_action_event(payload)

      {type, _name}
      when type in ["conversationUpdate", "installationUpdate", "event", "typing"] ->
        {:ok, :noop}

      {nil, _name} ->
        {:error, :missing_activity_type}

      {type, _name} ->
        {:error, {:unsupported_activity_type, type}}
    end
  end

  @impl true
  def format_webhook_response(result, opts \\ [])

  def format_webhook_response(
        {:ok, _chat, %EventEnvelope{event_type: :options_load, payload: payload}},
        _opts
      ) do
    format_options_load_response({:ok, payload})
  end

  def format_webhook_response({:ok, %OptionsLoadResult{} = result}, _opts) do
    format_options_load_response({:ok, result})
  end

  def format_webhook_response({:error, %OptionsLoadError{} = error}, _opts) do
    format_options_load_response({:error, error})
  end

  def format_webhook_response({:ok, _chat, _event}, opts) do
    case Keyword.get(opts, :invoke_response) do
      nil ->
        WebhookResponse.new(%{status: 200, headers: %{"content-type" => "text/plain"}, body: ""})

      response ->
        WebhookResponse.new(%{
          status: 200,
          headers: %{"content-type" => "application/json"},
          body: response
        })
    end
  end

  def format_webhook_response({:error, reason}, _opts)
      when reason in [
             :missing_authorization,
             :invalid_authorization,
             :invalid_signature,
             :invalid_issuer,
             :invalid_audience,
             :expired_token,
             :token_not_yet_valid,
             :service_url_mismatch
           ] do
    WebhookResponse.error(401, %{error: to_string(reason)})
  end

  def format_webhook_response({:error, reason}, _opts) do
    WebhookResponse.error(400, %{error: inspect(reason)})
  end

  @doc "Formats a typed options-load result as a Teams search invoke response."
  @spec format_options_load_response(
          {:ok, OptionsLoadResult.t()}
          | {:error, OptionsLoadError.t()}
        ) :: WebhookResponse.t()
  def format_options_load_response({:ok, %OptionsLoadResult{} = result}) do
    WebhookResponse.new(%{
      status: 200,
      headers: %{"content-type" => "application/json"},
      body: %{
        "type" => "application/vnd.microsoft.search.searchResponse",
        "value" => %{
          "results" =>
            Enum.map(result.options, fn option ->
              %{"title" => option.label, "value" => option.value}
            end)
        }
      }
    })
  end

  def format_options_load_response({:error, %OptionsLoadError{} = error}) do
    status = if(error.kind == :timeout, do: 504, else: 400)

    WebhookResponse.new(%{
      status: status,
      headers: %{"content-type" => "application/json"},
      body: %{
        "error" => %{
          "code" => error.code,
          "message" => error.message,
          "retryable" => error.retryable
        }
      }
    })
  end

  @impl true
  def handle_webhook(%Jido.Chat{} = chat, payload, opts \\ []) when is_map(payload) do
    request =
      WebhookRequest.new(%{
        adapter_name: :teams,
        headers: opts[:headers] || %{},
        payload: payload,
        raw: opts[:raw_body] || payload
      })

    with :ok <- verify_webhook(request, opts),
         {:ok, event} <- parse_event(request, opts),
         {:ok, next_chat, incoming} <- route_event(chat, event, opts) do
      {:ok, next_chat, incoming}
    end
  end

  defp route_event(chat, :noop, _opts) do
    {:ok, chat,
     Incoming.new(%{
       external_room_id: "team:noop",
       external_message_id: Jido.Chat.ID.generate!(),
       text: nil,
       metadata: %{noop: true}
     })}
  end

  defp route_event(chat, %EventEnvelope{} = envelope, opts) do
    with {:ok, next_chat, routed_event} <- Jido.Chat.process_event(chat, :teams, envelope, opts) do
      incoming =
        case routed_event.payload do
          %Incoming{} = incoming ->
            incoming

          _other ->
            Incoming.new(%{
              external_room_id: routed_event.channel_id || "team:event",
              external_message_id: routed_event.message_id || routed_event.id,
              text: nil,
              metadata: %{event_type: routed_event.event_type}
            })
        end

      {:ok, next_chat, incoming}
    end
  end

  defp send_activity(reference, activity, opts) do
    case opts[:reply_to_id] || opts[:external_reply_to_id] do
      nil ->
        transport(opts).send_activity(reference, activity, opts)

      reply_to_id ->
        transport(opts).reply_to_activity(reference, stringify(reply_to_id), activity, opts)
    end
  end

  defp transport(opts), do: Keyword.get(opts, :transport, ReqClient)

  defp message_activity(text, opts) do
    %{
      "type" => "message",
      "text" => text,
      "textFormat" => Keyword.get(opts, :text_format, "markdown")
    }
    |> maybe_put("entities", opts[:entities])
    |> maybe_put("channelData", opts[:channel_data])
  end

  defp card_activity(card, payload, opts) do
    %{
      "type" => "message",
      "text" => PostPayload.display_text(payload) || "",
      "attachments" => [
        %{
          "contentType" => @card_content_type,
          "content" => card
        }
      ]
    }
    |> maybe_put("channelData", opts[:channel_data])
  end

  defp render_card(nil), do: {:error, :missing_card}

  defp render_card(card) do
    {:ok, CardRenderer.render(card)}
  rescue
    _exception -> {:error, :invalid_card}
  end

  defp response(reference, external_room_id, result, status) do
    message_id = value(result, :id) || value(result, :activityId)

    Response.new(%{
      external_message_id: message_id,
      external_room_id: external_room_id,
      channel_type: :teams,
      status: status,
      raw: result,
      metadata: %{
        conversation_id: reference.conversation_id,
        conversation_ref: ConversationRef.encode(reference)
      }
    })
  end

  defp put_result_id(result, message_id) when is_map(result) do
    if value(result, :id) || value(result, :activityId) do
      result
    else
      Map.put(result, "id", stringify(message_id))
    end
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

  defp activity_scope(_conversation, team, channel)
       when map_size(team) > 0 or map_size(channel) > 0,
       do: :channel

  defp activity_scope(conversation, _team, _channel) do
    case value(conversation, :conversationType) do
      "personal" -> :personal
      "groupChat" -> :group_chat
      "channel" -> :channel
      _other -> nil
    end
  end

  defp external_room_id(%ConversationRef{scope: :channel} = reference) do
    reference.channel_id || reference.team_id || reference.conversation_id
  end

  defp external_room_id(%ConversationRef{} = reference), do: reference.conversation_id

  defp chat_type(:personal), do: :private
  defp chat_type(:group_chat), do: :group
  defp chat_type(:channel), do: :channel
  defp chat_type(_scope), do: :private

  defp chat_title(payload) do
    channel_data = value(payload, :channelData) || %{}
    channel = value(channel_data, :channel) || %{}
    team = value(channel_data, :team) || %{}
    value(channel, :name) || value(team, :name)
  end

  defp parse_mentions(payload) do
    recipient_id = value(value(payload, :recipient) || %{}, :id)

    payload
    |> value(:entities)
    |> List.wrap()
    |> Enum.flat_map(fn entity ->
      if value(entity, :type) == "mention" do
        mentioned = value(entity, :mentioned) || %{}
        user_id = stringify(value(mentioned, :id))

        [
          %{
            user_id: user_id,
            username: value(mentioned, :name),
            display_name: value(mentioned, :name),
            mention_text: value(entity, :text),
            is_self: not is_nil(user_id) and user_id == stringify(recipient_id),
            metadata: %{}
          }
        ]
      else
        []
      end
    end)
  end

  defp clean_text(text, mentions) when is_binary(text) do
    mentions
    |> Enum.filter(& &1.is_self)
    |> Enum.reduce(text, fn mention, acc ->
      case mention.mention_text do
        mention_text when is_binary(mention_text) -> String.replace(acc, mention_text, "")
        _other -> acc
      end
    end)
    |> String.trim()
  end

  defp clean_text(_text, _mentions), do: nil

  defp extract_media(payload) do
    payload
    |> value(:attachments)
    |> List.wrap()
    |> Enum.flat_map(fn attachment ->
      content_type = attachment |> value(:contentType) |> normalize_media_type()
      content_url = attachment |> value(:contentUrl) |> blank_to_nil()
      filename = attachment |> value(:name) |> blank_to_nil()

      if card_content_type?(content_type) or is_nil(content_url) do
        []
      else
        [
          %{
            kind: attachment_kind(content_type, filename, content_url),
            url: content_url,
            media_type: content_type,
            filename: filename,
            metadata: %{content: value(attachment, :content)}
          }
        ]
      end
    end)
  end

  defp card_content_type?(nil), do: false

  defp card_content_type?(content_type),
    do: canonical_media_type(content_type) == @card_content_type

  defp attachment_kind(media_type, filename, url) do
    media_kind_from_type(media_type) ||
      media_kind_from_reference(filename) ||
      media_kind_from_reference(url) ||
      :file
  end

  defp media_kind_from_type(media_type) when is_binary(media_type) do
    case canonical_media_type(media_type) do
      "image/" <> _rest -> :image
      "audio/" <> _rest -> :audio
      "video/" <> _rest -> :video
      _other -> :file
    end
  end

  defp media_kind_from_type(_media_type), do: nil

  defp media_kind_from_reference(reference) when is_binary(reference) do
    reference
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      path when is_binary(path) -> path |> Path.extname() |> String.downcase()
      _other -> ""
    end
    |> then(&Map.get(@media_kind_extensions, &1))
  end

  defp media_kind_from_reference(_reference), do: nil

  defp normalize_media_type(value) when is_binary(value) do
    trimmed = String.trim(value)

    if Regex.match?(@media_type_pattern, canonical_media_type(trimmed)),
      do: trimmed,
      else: nil
  end

  defp normalize_media_type(_value), do: nil

  defp canonical_media_type(value) do
    value
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_value), do: nil

  defp parse_reaction_event(payload) do
    added = value(payload, :reactionsAdded) |> List.wrap()
    removed = value(payload, :reactionsRemoved) |> List.wrap()

    {reaction, added?} =
      if added == [], do: {List.first(removed), false}, else: {List.first(added), true}

    if is_map(reaction) do
      conversation = value(payload, :conversation) || %{}
      from = value(payload, :from) || %{}
      activity_id = stringify(value(payload, :replyToId) || value(payload, :id))
      channel_id = conversation |> value(:id) |> stringify()

      event =
        ReactionEvent.new(%{
          adapter: __MODULE__,
          adapter_name: :teams,
          thread_id: channel_id,
          channel_id: channel_id,
          message_id: activity_id,
          emoji: stringify(value(reaction, :type)),
          added: added?,
          user: %{
            user_id: stringify(value(from, :aadObjectId) || value(from, :id)),
            user_name: value(from, :name)
          },
          raw: normalize_struct(payload),
          metadata: %{reactions_added: added, reactions_removed: removed}
        })

      {:ok,
       EventEnvelope.new(%{
         id: stringify(value(payload, :id)) || Jido.Chat.ID.generate!(),
         adapter_name: :teams,
         event_type: :reaction,
         thread_id: channel_id,
         channel_id: channel_id,
         message_id: activity_id,
         payload: event,
         raw: normalize_struct(payload)
       })}
    else
      {:error, :missing_reaction}
    end
  end

  defp parse_action_event(payload) do
    conversation = value(payload, :conversation) || %{}
    from = value(payload, :from) || %{}
    raw_value = value(payload, :value) || %{}
    action = value(raw_value, :action) || raw_value
    channel_id = stringify(value(conversation, :id))
    message_id = stringify(value(payload, :replyToId) || value(payload, :id))

    event =
      ActionEvent.new(%{
        adapter: __MODULE__,
        adapter_name: :teams,
        thread_id: channel_id,
        channel_id: channel_id,
        message_id: message_id,
        action_id:
          stringify(value(action, :verb) || value(action, :action_id) || value(payload, :name)),
        value: action_value(action),
        trigger_id: stringify(value(payload, :id)),
        user: %{
          user_id: stringify(value(from, :aadObjectId) || value(from, :id)),
          user_name: value(from, :name)
        },
        raw: normalize_struct(payload),
        metadata: %{invoke_name: value(payload, :name)}
      })

    {:ok,
     EventEnvelope.new(%{
       id: stringify(value(payload, :id)) || Jido.Chat.ID.generate!(),
       adapter_name: :teams,
       event_type: :action,
       thread_id: channel_id,
       channel_id: channel_id,
       message_id: message_id,
       payload: event,
       raw: normalize_struct(payload)
     })}
  end

  defp parse_options_load_event(payload) do
    conversation = value(payload, :conversation) || %{}
    from = value(payload, :from) || %{}
    request = value(payload, :value) || %{}
    query_options = value(request, :queryOptions) || %{}
    channel_id = stringify(value(conversation, :id))
    message_id = stringify(value(payload, :replyToId) || value(payload, :id))

    dataset = stringify(value(request, :dataset) || value(request, :action_id))

    if is_binary(dataset) and String.trim(dataset) != "" do
      event =
        OptionsLoadEvent.new(%{
          adapter: __MODULE__,
          adapter_name: :teams,
          action_id: dataset,
          query: stringify(value(request, :queryText)) || "",
          limit: positive_integer(value(query_options, :top)),
          timeout_ms: positive_integer(value(request, :timeoutMs)),
          thread_id: channel_id,
          channel_id: channel_id,
          message_id: message_id,
          user: %{
            user_id: stringify(value(from, :aadObjectId) || value(from, :id)),
            user_name: value(from, :name)
          },
          raw: normalize_struct(payload),
          metadata: %{
            associated_inputs: normalize_struct(value(request, :data) || %{}),
            skip: non_negative_integer(value(query_options, :skip))
          }
        })

      {:ok,
       EventEnvelope.new(%{
         id: stringify(value(payload, :id)) || Jido.Chat.ID.generate!(),
         adapter_name: :teams,
         event_type: :options_load,
         thread_id: channel_id,
         channel_id: channel_id,
         message_id: message_id,
         payload: event,
         raw: normalize_struct(payload),
         metadata: %{invoke_name: "application/search"}
       })}
    else
      {:error, :missing_options_dataset}
    end
  end

  defp fetch_options_loader(opts) do
    case opts[:options_loader] do
      loader when is_function(loader, 1) or is_function(loader, 2) ->
        {:ok, loader}

      {module, function, args} = loader
      when is_atom(module) and is_atom(function) and is_list(args) ->
        {:ok, loader}

      nil ->
        {:error, options_error("options_loader_unavailable", "No options loader is configured")}

      _other ->
        {:error, options_error("invalid_options_loader", "The options loader is invalid")}
    end
  end

  defp call_options_loader(loader, event, opts, timeout_ms) do
    caller = self()
    reply_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(caller, {reply_ref, safely_invoke_options_loader(loader, event, opts)})
      end)

    receive do
      {^reply_ref, {:ok, result}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, result}

      {^reply_ref, {:error, reason}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, options_loader_error(reason)}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, options_loader_error(reason)}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        receive do: ({:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok)

        receive do
          {^reply_ref, _late_result} -> :ok
        after
          0 -> :ok
        end

        {:error, OptionsLoadError.timeout(timeout_ms)}
    end
  end

  defp invoke_options_loader(loader, event, opts) when is_function(loader, 2),
    do: loader.(event, opts)

  defp invoke_options_loader(loader, event, _opts) when is_function(loader, 1),
    do: loader.(event)

  defp invoke_options_loader({module, function, args}, event, opts),
    do: apply(module, function, [event, opts | args])

  defp safely_invoke_options_loader(loader, event, opts) do
    {:ok, invoke_options_loader(loader, event, opts)}
  rescue
    exception -> {:error, {exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_options_result({:ok, %OptionsLoadResult{} = result}, _timeout_ms),
    do: {:ok, result}

  defp normalize_options_result({:ok, result}, _timeout_ms) when is_map(result) do
    {:ok, OptionsLoadResult.new(result)}
  rescue
    exception -> {:error, options_loader_error(exception)}
  end

  defp normalize_options_result({:error, %OptionsLoadError{} = error}, _timeout_ms),
    do: {:error, error}

  defp normalize_options_result({:error, :timeout}, timeout_ms),
    do: {:error, OptionsLoadError.timeout(timeout_ms)}

  defp normalize_options_result({:error, reason}, _timeout_ms),
    do: {:error, options_loader_error(reason)}

  defp normalize_options_result(other, _timeout_ms),
    do:
      {:error,
       options_error(
         "invalid_options_loader_result",
         "The options loader returned an invalid result",
         %{result: inspect(other)}
       )}

  defp validate_options_result(%OptionsLoadResult{option_groups: [_ | _]}, _event) do
    {:error,
     options_error(
       "teams_option_groups_unsupported",
       "Teams dynamic-search responses do not support option groups"
     )}
  end

  defp validate_options_result(%OptionsLoadResult{options: options}, event) do
    max_choices = CardRenderer.max_choices()
    limit = min(event.limit || max_choices, max_choices)
    option_count = length(options)

    if option_count <= limit do
      :ok
    else
      {:error,
       options_error(
         "teams_option_limit",
         "Teams dynamic-search responses support at most #{limit} options",
         %{actual: option_count, limit: limit}
       )}
    end
  end

  defp options_loader_error(reason) do
    options_error(
      "options_loader_error",
      "The options loader failed",
      %{reason: inspect(reason)}
    )
  end

  defp options_error(code, message, metadata \\ %{}) do
    OptionsLoadError.new(%{
      code: code,
      message: message,
      retryable: false,
      metadata: metadata
    })
  end

  defp action_value(value) when is_binary(value), do: value

  defp action_value(value) when is_map(value) do
    case value(value, :value) do
      nested when is_binary(nested) -> nested
      _other -> Jason.encode!(normalize_struct(value))
    end
  end

  defp action_value(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(_map, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp normalize_struct(%_{} = struct), do: struct |> Map.from_struct() |> normalize_struct()

  defp normalize_struct(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, normalize_struct(value)} end)

  defp normalize_struct(list) when is_list(list), do: Enum.map(list, &normalize_struct/1)
  defp normalize_struct(value), do: value
end
