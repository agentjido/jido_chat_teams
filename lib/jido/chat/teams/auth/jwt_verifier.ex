defmodule Jido.Chat.Teams.Auth.JwtVerifier do
  @moduledoc "Verifies signed Microsoft Bot Connector Activities."

  alias Jido.Chat.Teams.Auth

  @default_issuer "https://api.botframework.com"
  @default_keys_url "https://login.botframework.com/v1/.well-known/keys"
  @keys_table :jido_chat_teams_openid_keys_cache
  @cache_seconds 21_600
  @clock_skew_seconds 300

  @doc "Verifies an Activity against its authorization header and Client credentials."
  @spec verify(map(), map() | list(), map(), keyword()) :: :ok | {:error, term()}
  def verify(payload, headers, credentials, opts \\ []) do
    case verify_with_claims(payload, headers, credentials, opts) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Verifies an Activity and returns its JWT claims."
  @spec verify_with_claims(map(), map() | list(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_with_claims(payload, headers, credentials, opts \\ [])
      when is_map(payload) and is_map(credentials) and is_list(opts) do
    with {:ok, token} <- bearer_token(headers),
         {:ok, app_id} <- Auth.credential(credentials, :app_id),
         {:ok, keys} <- signing_keys(opts),
         {:ok, claims} <- verify_signature(token, keys),
         :ok <- validate_claims(claims, payload, app_id, opts) do
      {:ok, claims}
    end
  end

  @doc false
  def clear_cache do
    ensure_table()
    :ets.delete_all_objects(@keys_table)
    :ok
  end

  defp bearer_token(headers) do
    headers
    |> header("authorization")
    |> parse_authorization()
  end

  defp parse_authorization(value) when is_binary(value),
    do: value |> String.split(~r/\s+/, parts: 2, trim: true) |> parse_bearer()

  defp parse_authorization(_), do: {:error, :missing_authorization}

  defp parse_bearer([scheme, token]) when token != "" do
    if String.downcase(scheme) == "bearer",
      do: {:ok, token},
      else: {:error, :invalid_authorization}
  end

  defp parse_bearer(_), do: {:error, :invalid_authorization}

  defp signing_keys(opts) do
    case opts[:jwks] do
      %{"keys" => keys} when is_list(keys) -> {:ok, keys}
      %{keys: keys} when is_list(keys) -> {:ok, keys}
      keys when is_list(keys) -> {:ok, keys}
      _ -> cached_signing_keys(opts)
    end
  end

  defp cached_signing_keys(opts) do
    ensure_table()
    url = opts[:openid_keys_url] || @default_keys_url
    now = System.system_time(:second)

    case :ets.lookup(@keys_table, url) do
      [{^url, keys, expires_at}] when expires_at > now ->
        {:ok, keys}

      _ ->
        with {:ok, keys} <- fetch_signing_keys(url, opts) do
          true =
            :ets.insert(
              @keys_table,
              {url, keys, now + (opts[:openid_cache_seconds] || @cache_seconds)}
            )

          {:ok, keys}
        end
    end
  end

  defp fetch_signing_keys(url, opts) do
    req = opts[:req] || Req

    case req.request(method: :get, url: url, retry: false, redirect: false) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case body do
          %{"keys" => keys} when is_list(keys) -> {:ok, keys}
          %{keys: keys} when is_list(keys) -> {:ok, keys}
          _ -> {:error, {:openid_keys_error, status, body}}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:openid_keys_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_signature(token, keys) do
    Enum.find_value(keys, {:error, :invalid_signature}, fn key ->
      try do
        case JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["RS256"], token) do
          {true, %JOSE.JWT{fields: claims}, _} when is_map(claims) -> {:ok, claims}
          _ -> nil
        end
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end
    end)
  end

  defp validate_claims(claims, payload, app_id, opts) do
    now = opts[:now] || System.system_time(:second)
    skew = opts[:clock_skew_seconds] || @clock_skew_seconds
    service_url = payload["serviceUrl"] || payload[:serviceUrl]
    token_service_url = claims["serviceurl"] || claims["serviceUrl"]

    with :ok <- valid_issuer(claims["iss"], opts[:issuer] || @default_issuer),
         :ok <- valid_audience(claims["aud"], app_id),
         :ok <- valid_expiry(claims["exp"], now, skew),
         :ok <- valid_not_before(claims["nbf"], now, skew),
         :ok <- valid_service_url(service_url) do
      matching_service_url(token_service_url, service_url)
    end
  end

  defp valid_issuer(issuer, issuer), do: :ok
  defp valid_issuer(_, _), do: {:error, :invalid_issuer}

  defp valid_audience(value, app_id) when is_binary(value) and value == app_id, do: :ok
  defp valid_audience(value, app_id) when is_list(value), do: member_result(app_id in value)
  defp valid_audience(_, _), do: {:error, :invalid_audience}

  defp member_result(true), do: :ok
  defp member_result(false), do: {:error, :invalid_audience}

  defp valid_expiry(expiry, now, skew)
       when is_integer(expiry) and expiry >= now - skew,
       do: :ok

  defp valid_expiry(_, _, _), do: {:error, :expired_token}

  defp valid_not_before(nil, _, _), do: :ok
  defp valid_not_before(value, now, skew) when is_integer(value) and value <= now + skew, do: :ok
  defp valid_not_before(_, _, _), do: {:error, :token_not_yet_valid}

  defp valid_service_url(value) when is_binary(value) and value != "", do: :ok
  defp valid_service_url(_), do: {:error, :missing_service_url}

  defp matching_service_url(token_url, activity_url) do
    if normalize_url(token_url) == normalize_url(activity_url),
      do: :ok,
      else: {:error, :service_url_mismatch}
  end

  defp normalize_url(value) when is_binary(value), do: String.trim_trailing(value, "/")
  defp normalize_url(_), do: nil

  defp header(headers, name) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: value
    end)
    |> header_value()
  end

  defp header_value([first | _]), do: first
  defp header_value(value), do: value

  defp ensure_table do
    case :ets.whereis(@keys_table) do
      :undefined ->
        try do
          :ets.new(@keys_table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @keys_table
        end

      table ->
        table
    end
  end
end
