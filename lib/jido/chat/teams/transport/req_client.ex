defmodule Jido.Chat.Teams.Transport.ReqClient do
  @moduledoc """
  `Req` transport for Microsoft Bot Connector activities and inbound media.
  """

  @behaviour Jido.Chat.Teams.Transport

  alias Jido.Chat.Teams.Auth
  alias Jido.Chat.Teams.ConversationRef

  @default_service_hosts [
    "smba.trafficmanager.net",
    "smba.infra.gcc.teams.microsoft.com",
    "smba.infra.gov.teams.microsoft.us",
    "smba.infra.dod.teams.microsoft.us"
  ]

  # Hosts of the pre-authenticated `downloadUrl` of files sent in a personal chat.
  @default_file_hosts ["sharepoint.com", "sharepoint.us", "sharepoint-mil.us"]

  @media_redirect_statuses [301, 302, 303, 307, 308]
  @max_media_redirects 3

  @impl true
  def send_activity(credentials, %ConversationRef{} = reference, activity, opts) do
    request(
      credentials,
      :post,
      activity_url(reference),
      activity,
      reference,
      opts
    )
  end

  @impl true
  def reply_to_activity(credentials, %ConversationRef{} = reference, activity_id, activity, opts) do
    request(
      credentials,
      :post,
      activity_url(reference, activity_id),
      activity,
      reference,
      opts
    )
  end

  @impl true
  def update_activity(credentials, %ConversationRef{} = reference, activity_id, activity, opts) do
    request(
      credentials,
      :put,
      activity_url(reference, activity_id),
      activity,
      reference,
      opts
    )
  end

  @impl true
  def delete_activity(credentials, %ConversationRef{} = reference, activity_id, opts) do
    request(
      credentials,
      :delete,
      activity_url(reference, activity_id),
      nil,
      reference,
      opts
    )
  end

  @doc """
  Downloads media bytes coming from Teams attachments.

  Teams sends no attachment size. With a positive integer in `:max_media_bytes`,
  the download stops once the declared or received size passes it and returns
  `{:error, :media_too_large}`. An invalid limit returns
  `{:error, :invalid_max_media_bytes}`. Without a limit, the whole file is
  downloaded.
  """
  @impl true
  def download_media(credentials, url, opts) when is_map(credentials) and is_binary(url) do
    with {:ok, max_bytes} <- max_media_bytes(opts) do
      download_media(credentials, url, opts, max_bytes, @max_media_redirects)
    end
  end

  defp download_media(credentials, url, opts, max_bytes, redirects_left) do
    case media_auth(url, opts) do
      {:ok, :bot_token} ->
        download_with_token(credentials, url, opts, true, max_bytes, redirects_left)

      {:ok, :pre_authenticated} ->
        download(credentials, url, nil, opts, false, max_bytes, redirects_left)

      {:error, _reason} = error ->
        error
    end
  end

  defp media_auth(url, opts), do: url |> URI.parse() |> uri_auth(opts)

  defp uri_auth(%URI{scheme: "https", host: host}, opts) when is_binary(host) do
    cond do
      trusted_host?(host, service_hosts(opts)) -> {:ok, :bot_token}
      trusted_host?(host, file_hosts(opts)) -> {:ok, :pre_authenticated}
      true -> {:error, :untrusted_media_url}
    end
  end

  defp uri_auth(_uri, _opts), do: {:error, :invalid_media_url}

  defp service_hosts(opts), do: Keyword.get(opts, :allowed_service_hosts, @default_service_hosts)
  defp file_hosts(opts), do: Keyword.get(opts, :allowed_file_hosts, @default_file_hosts)

  defp download(credentials, url, token, opts, retry_auth?, max_bytes, redirects_left) do
    req = Keyword.get(opts, :req, Req)

    request_opts =
      limit_download(
        [
          method: :get,
          url: url,
          headers: media_headers(token),
          decode_body: false,
          retry: false,
          redirect: false
        ],
        max_bytes
      )

    case req.request(request_opts) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        media_body(response, max_bytes)

      {:ok, %Req.Response{status: status} = response}
      when status in @media_redirect_statuses ->
        follow_media_redirect(credentials, response, url, opts, max_bytes, redirects_left)

      {:ok, %Req.Response{status: 401}} ->
        retry_unauthorized(credentials, url, opts, retry_auth?, max_bytes, redirects_left)

      {:ok, %Req.Response{status: 429} = response} ->
        {:error, {:rate_limited, retry_after_ms(response)}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp follow_media_redirect(_credentials, _response, _url, _opts, _max_bytes, 0),
    do: {:error, :too_many_redirects}

  defp follow_media_redirect(credentials, response, url, opts, max_bytes, redirects_left) do
    with [location | _rest] when is_binary(location) and location != "" <-
           Req.Response.get_header(response, "location"),
         {:ok, redirect_url} <- resolve_redirect_url(url, location) do
      download_media(credentials, redirect_url, opts, max_bytes, redirects_left - 1)
    else
      _other -> {:error, :invalid_media_redirect}
    end
  end

  defp resolve_redirect_url(url, location) do
    {:ok, url |> URI.merge(location) |> URI.to_string()}
  rescue
    ArgumentError -> {:error, :invalid_media_redirect}
  end

  defp media_body(%Req.Response{body: body} = response, max_bytes) when is_binary(body) do
    if too_large?(response, max_bytes), do: {:error, :media_too_large}, else: {:ok, body}
  end

  defp media_body(_response, _max_bytes), do: {:error, :invalid_media_body}

  defp retry_unauthorized(credentials, url, opts, retry_auth?, max_bytes, redirects_left) do
    if retry_auth? and is_nil(Keyword.get(opts, :access_token)) do
      download_with_token(credentials, url, opts, false, max_bytes, redirects_left)
    else
      {:error, {:http_error, 401}}
    end
  end

  defp download_with_token(credentials, url, opts, retry_auth?, max_bytes, redirects_left) do
    with {:ok, token} <- access_token(credentials, opts) do
      download(credentials, url, token, opts, retry_auth?, max_bytes, redirects_left)
    end
  end

  defp media_headers(nil), do: []
  defp media_headers(token), do: [{"authorization", "Bearer #{token}"}]

  defp limit_download(request_opts, nil), do: request_opts

  defp limit_download(request_opts, max_bytes),
    do: Keyword.put(request_opts, :into, &collect_media(&1, &2, max_bytes))

  defp collect_media({:data, data}, {request, response}, max_bytes) do
    response = %{response | body: response.body <> data}

    if too_large?(response, max_bytes),
      do: {:halt, {request, response}},
      else: {:cont, {request, response}}
  end

  defp too_large?(_response, nil), do: false

  defp too_large?(%Req.Response{body: body} = response, max_bytes) do
    byte_size(body) > max_bytes or declared_size(response) > max_bytes
  end

  defp declared_size(response) do
    with [value | _rest] <- Req.Response.get_header(response, "content-length"),
         {size, ""} <- Integer.parse(value) do
      size
    else
      _other -> 0
    end
  end

  defp max_media_bytes(opts) do
    case Keyword.fetch(opts, :max_media_bytes) do
      :error -> {:ok, nil}
      {:ok, max_bytes} when is_integer(max_bytes) and max_bytes > 0 -> {:ok, max_bytes}
      {:ok, _other} -> {:error, :invalid_max_media_bytes}
    end
  end

  defp request(credentials, method, url, body, reference, opts) do
    with :ok <- validate_service_url(reference.service_url, opts),
         {:ok, token} <- access_token(credentials, opts) do
      do_request(credentials, method, url, body, token, opts, true)
    end
  end

  defp do_request(credentials, method, url, body, token, opts, retry_auth?) do
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

    context = %{
      credentials: credentials,
      method: method,
      url: url,
      body: body,
      opts: opts,
      retry_auth?: retry_auth?
    }

    req.request(request_opts) |> handle_activity_response(context)
  end

  defp handle_activity_response(
         {:ok, %Req.Response{status: status}},
         %{method: :delete}
       )
       when status in 200..299,
       do: {:ok, true}

  defp handle_activity_response({:ok, %Req.Response{status: status, body: body}}, _context)
       when status in 200..299,
       do: {:ok, normalize_body(body)}

  defp handle_activity_response(
         {:ok, %Req.Response{status: 401, body: response_body}},
         context
       ),
       do: retry_activity_auth(context, response_body)

  defp handle_activity_response({:ok, %Req.Response{status: 429} = response}, _context),
    do: {:error, {:rate_limited, retry_after_ms(response)}}

  defp handle_activity_response({:ok, %Req.Response{status: status}}, _context)
       when status in [412, 502, 503, 504],
       do: {:error, {:http_error, status}}

  defp handle_activity_response(
         {:ok, %Req.Response{status: status, body: response_body}},
         _context
       ),
       do: {:error, {:http_error, status, response_body}}

  defp handle_activity_response({:error, reason}, _context), do: {:error, reason}

  defp retry_activity_auth(context, response_body) do
    if context.retry_auth? and is_nil(Keyword.get(context.opts, :access_token)) do
      retry_activity_with_fresh_token(context)
    else
      {:error, {:http_error, 401, response_body}}
    end
  end

  defp retry_activity_with_fresh_token(context) do
    with {:ok, next_token} <- access_token(context.credentials, context.opts) do
      do_request(
        context.credentials,
        context.method,
        context.url,
        context.body,
        next_token,
        context.opts,
        false
      )
    end
  end

  defp access_token(credentials, opts) do
    case opts[:access_token] do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> with {:ok, token} <- Auth.fetch_token(credentials, opts), do: {:ok, token.access_token}
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
