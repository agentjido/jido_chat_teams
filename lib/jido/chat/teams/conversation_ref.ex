defmodule Jido.Chat.Teams.ConversationRef do
  @moduledoc """
  Versioned Microsoft Teams conversation delivery reference.

  Teams replies need both the Bot Connector conversation ID and the verified
  service URL from an inbound activity. The encoded form is safe to persist as
  `delivery_external_room_id`. It contains routing data, but no secret.
  """

  @prefix "teamsref:v1:"

  @enforce_keys [:conversation_id, :service_url]
  defstruct [
    :conversation_id,
    :service_url,
    :tenant_id,
    :scope,
    :team_id,
    :channel_id,
    :bot_id,
    :user_id
  ]

  @type scope :: :personal | :group_chat | :channel | nil

  @type t :: %__MODULE__{
          conversation_id: String.t(),
          service_url: String.t(),
          tenant_id: String.t() | nil,
          scope: scope(),
          team_id: String.t() | nil,
          channel_id: String.t() | nil,
          bot_id: String.t() | nil,
          user_id: String.t() | nil
        }

  @doc "Builds a validated conversation reference."
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    conversation_id = value(attrs, :conversation_id)
    service_url = value(attrs, :service_url)

    if blank?(conversation_id) or blank?(service_url) do
      raise ArgumentError, "conversation_id and service_url are required"
    end

    %__MODULE__{
      conversation_id: to_string(conversation_id),
      service_url: normalize_service_url(service_url),
      tenant_id: stringify(value(attrs, :tenant_id)),
      scope: normalize_scope(value(attrs, :scope)),
      team_id: stringify(value(attrs, :team_id)),
      channel_id: stringify(value(attrs, :channel_id)),
      bot_id: stringify(value(attrs, :bot_id)),
      user_id: stringify(value(attrs, :user_id))
    }
  end

  @doc "Encodes a conversation reference for persistence and adapter routing."
  @spec encode(t() | map() | keyword()) :: String.t()
  def encode(%__MODULE__{} = reference) do
    reference
    |> to_map()
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
    |> then(&(@prefix <> &1))
  end

  def encode(attrs), do: attrs |> new() |> encode()

  @doc "Decodes a versioned conversation reference."
  @spec decode(String.t()) :: {:ok, t()} | {:error, term()}
  def decode(@prefix <> encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, attrs} when is_map(attrs) <- Jason.decode(json) do
      {:ok, new(attrs)}
    else
      :error -> {:error, :invalid_conversation_reference}
      {:error, _reason} -> {:error, :invalid_conversation_reference}
      _other -> {:error, :invalid_conversation_reference}
    end
  rescue
    ArgumentError -> {:error, :invalid_conversation_reference}
  end

  def decode(_value), do: {:error, :invalid_conversation_reference}

  @doc "Resolves a struct, encoded reference, map, or conversation ID."
  @spec cast(t() | map() | String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def cast(value, opts \\ [])

  def cast(%__MODULE__{} = reference, _opts), do: {:ok, reference}

  def cast(value, _opts) when is_map(value) do
    {:ok, new(value)}
  rescue
    ArgumentError -> {:error, :invalid_conversation_reference}
  end

  def cast(@prefix <> _rest = encoded, _opts), do: decode(encoded)

  def cast(conversation_id, opts) when is_binary(conversation_id) do
    service_url = option(opts, :service_url)

    if blank?(service_url) do
      {:error, :missing_conversation_reference}
    else
      attrs = %{
        conversation_id: conversation_id,
        service_url: service_url,
        tenant_id: option(opts, :tenant_id),
        scope: option(opts, :scope),
        team_id: option(opts, :team_id),
        channel_id: option(opts, :channel_id),
        bot_id: option(opts, :bot_id),
        user_id: option(opts, :user_id)
      }

      cast(attrs, opts)
    end
  end

  def cast(_value, _opts), do: {:error, :invalid_conversation_reference}

  @doc "Returns a plain map suitable for JSON encoding."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = reference) do
    %{
      "conversation_id" => reference.conversation_id,
      "service_url" => reference.service_url,
      "tenant_id" => reference.tenant_id,
      "scope" => reference.scope && Atom.to_string(reference.scope),
      "team_id" => reference.team_id,
      "channel_id" => reference.channel_id,
      "bot_id" => reference.bot_id,
      "user_id" => reference.user_id
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_service_url(service_url) do
    service_url
    |> to_string()
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp normalize_scope(scope) when scope in [:personal, :group_chat, :channel], do: scope
  defp normalize_scope("personal"), do: :personal
  defp normalize_scope("groupChat"), do: :group_chat
  defp normalize_scope("group_chat"), do: :group_chat
  defp normalize_scope("channel"), do: :channel
  defp normalize_scope(_scope), do: nil

  defp option(opts, key) do
    Keyword.get(opts, key) || nested_option(Keyword.get(opts, :conversation_ref), key)
  end

  defp nested_option(map, key) when is_map(map), do: value(map, key)
  defp nested_option(_map, _key), do: nil

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp blank?(value), do: value in [nil, ""]
  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)
end
