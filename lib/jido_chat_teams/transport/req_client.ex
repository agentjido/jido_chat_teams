defmodule Jido.Chat.Teams.Transport.ReqClient do
  @moduledoc """
  `Req` transport for Microsoft Bot Connector activities.
  """

  @behaviour Jido.Chat.Teams.Transport

  alias Jido.Chat.Teams.Auth.TokenCache
  alias Jido.Chat.Teams.ConversationRef

  @default_service_hosts [
    "smba.trafficmanager.net",
    "smba.infra.gcc.teams.microsoft.com",
    "smba.infra.gov.teams.microsoft.us",
    "smba.infra.dod.teams.microsoft.us"
  ]

  @impl true
  def send_activity(%ConversationRef{} = reference, activity, opts) do
    request(
      :post,
      activity_url(reference),
      activity,
      reference,
      opts
    )
  end

  @impl true
  def reply_to_activity(%ConversationRef{} = reference, activity_id, activity, opts) do
    request(
      :post,
      activity_url(reference, activity_id),
      activity,
      reference,
      opts
    )
  end

  @impl true
  def update_activity(%ConversationRef{} = reference, activity_id, activity, opts) do
    request(
      :put,
      activity_url(reference, activity_id),
      activity,
      reference,
      opts
    )
  end

  @impl true
  def delete_activity(%ConversationRef{} = reference, activity_id, opts) do
    request(
      :delete,
      activity_url(reference, activity_id),
      nil,
      reference,
      opts
    )
  end

  defp request(method, url, body, reference, opts) do
    with :ok <- validate_service_url(reference.service_url, opts),
         {:ok, token} <- TokenCache.fetch(opts) do
      do_request(method, url, body, token, opts, true)
    end
  end

  defp do_request(method, url, body, token, opts, retry_auth?) do
    req = Keyword.get(opts, :req, Req)

    request_opts =
      [
        method: method,
        url: url,
        headers: [{"authorization", "Bearer #{token}"}],
        retry: false,
        redirect: false
      ]
      |> maybe_put_json(body)

    case req.request(request_opts) do
      {:ok, %Req.Response{status: status}} when status in 200..299 and method == :delete ->
        {:ok, true}

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize_body(body)}

      {:ok, %Req.Response{status: 401, body: response_body}} ->
        if retry_auth? and is_nil(Keyword.get(opts, :access_token)) do
          TokenCache.invalidate(opts)

          with {:ok, next_token} <- TokenCache.fetch(opts) do
            do_request(method, url, body, next_token, opts, false)
          end
        else
          {:error, {:http_error, 401, response_body}}
        end

      {:ok, %Req.Response{status: 429} = response} ->
        {:error, {:rate_limited, retry_after_ms(response)}}

      {:ok, %Req.Response{status: status}} when status in [412, 502, 503, 504] ->
        {:error, {:http_error, status}}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp activity_url(%ConversationRef{} = reference) do
    reference.service_url <>
      "/v3/conversations/" <> encode_segment(reference.conversation_id) <> "/activities"
  end

  defp activity_url(%ConversationRef{} = reference, activity_id) do
    activity_url(reference) <> "/" <> encode_segment(activity_id)
  end

  defp validate_service_url(service_url, opts) do
    uri = URI.parse(service_url)
    allowed_hosts = Keyword.get(opts, :allowed_service_hosts, @default_service_hosts)

    cond do
      uri.scheme != "https" -> {:error, :invalid_service_url}
      not is_binary(uri.host) -> {:error, :invalid_service_url}
      trusted_host?(uri.host, allowed_hosts) -> :ok
      true -> {:error, :untrusted_service_url}
    end
  end

  defp trusted_host?(host, allowed_hosts) do
    normalized_host = String.downcase(host)

    Enum.any?(allowed_hosts, fn allowed ->
      allowed = allowed |> to_string() |> String.downcase()
      normalized_host == allowed or String.ends_with?(normalized_host, "." <> allowed)
    end)
  end

  defp encode_segment(value) do
    value
    |> to_string()
    |> URI.encode(&URI.char_unreserved?/1)
  end

  defp maybe_put_json(opts, nil), do: opts
  defp maybe_put_json(opts, body), do: Keyword.put(opts, :json, body)

  defp normalize_body(body) when is_map(body), do: body
  defp normalize_body(""), do: %{}
  defp normalize_body(nil), do: %{}
  defp normalize_body(body), do: %{"body" => body}

  defp retry_after_ms(%Req.Response{} = response) do
    response
    |> Req.Response.get_header("retry-after")
    |> List.first()
    |> parse_retry_after()
  end

  defp parse_retry_after(nil), do: 1000

  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1000
      _other -> 1000
    end
  end
end
