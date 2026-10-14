defmodule Jido.Chat.Teams.Auth.JwtVerifier do
  @moduledoc """
  Verifies signed inbound Microsoft Bot Connector requests.

  Verification covers the RSA signature, algorithm, issuer, audience, token
  lifetime, and the exact Activity `serviceUrl` claim.
  """

  alias Jido.Chat.Teams.Auth
  alias Jido.Chat.WebhookRequest

  @default_issuer "https://api.botframework.com"
  @default_keys_url "https://login.botframework.com/v1/.well-known/keys"
  @keys_table :jido_chat_teams_openid_keys_cache
  @default_cache_seconds 21_600
  @default_clock_skew_seconds 300

  @doc "Verifies an inbound webhook request."
  @spec verify(WebhookRequest.t(), keyword()) :: :ok | {:error, term()}
  def verify(%WebhookRequest{} = request, opts \\ []) do
    case verify_with_claims(request, opts) do
      {:ok, _claims} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Verifies an inbound request and returns its JWT claims."
  @spec verify_with_claims(WebhookRequest.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify_with_claims(%WebhookRequest{} = request, opts \\ []) do
    with {:ok, token} <- bearer_token(request),
         {:ok, app_id} <- Auth.credential(opts, :app_id),
         {:ok, keys} <- signing_keys(opts),
         {:ok, claims} <- verify_signature(token, keys),
         :ok <- validate_claims(claims, request.payload, app_id, opts) do
      {:ok, claims}
    end
  end

  @doc false
  def clear_cache do
    ensure_table()
    :ets.delete_all_objects(@keys_table)
    :ok
  end

  defp bearer_token(%WebhookRequest{} = request) do
    case WebhookRequest.header(request, "authorization") do
      value when is_binary(value) ->
        case String.split(value, ~r/\s+/, parts: 2, trim: true) do
          [scheme, token] ->
            if String.downcase(scheme) == "bearer" and token != "" do
              {:ok, token}
            else
              {:error, :invalid_authorization}
            end

          _other ->
            {:error, :invalid_authorization}
        end

      _other ->
        {:error, :missing_authorization}
    end
  end

  defp signing_keys(opts) do
    case Keyword.get(opts, :jwks) do
      %{"keys" => keys} when is_list(keys) -> {:ok, keys}
      %{keys: keys} when is_list(keys) -> {:ok, keys}
      keys when is_list(keys) -> {:ok, keys}
      _other -> cached_signing_keys(opts)
    end
  end

  defp cached_signing_keys(opts) do
    ensure_table()
    url = Keyword.get(opts, :openid_keys_url, @default_keys_url)
    now = System.system_time(:second)

    case :ets.lookup(@keys_table, url) do
      [{^url, keys, expires_at}] when expires_at > now ->
        {:ok, keys}

      _other ->
        with {:ok, keys} <- fetch_signing_keys(url, opts) do
          cache_seconds = Keyword.get(opts, :openid_cache_seconds, @default_cache_seconds)
          true = :ets.insert(@keys_table, {url, keys, now + cache_seconds})
          {:ok, keys}
        end
    end
  end

  defp fetch_signing_keys(url, opts) do
    req = Keyword.get(opts, :req, Req)

    case req.request(method: :get, url: url, retry: false, redirect: false) do
      {:ok, %Req.Response{status: status, body: %{"keys" => keys}}}
      when status in 200..299 and is_list(keys) ->
        {:ok, keys}

      {:ok, %Req.Response{status: status, body: %{keys: keys}}}
      when status in 200..299 and is_list(keys) ->
        {:ok, keys}

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
          {true, %JOSE.JWT{fields: claims}, _jws} when is_map(claims) -> {:ok, claims}
          _other -> nil
        end
      rescue
        _exception -> nil
      catch
        _kind, _reason -> nil
      end
    end)
  end

  defp validate_claims(claims, payload, app_id, opts) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    skew = Keyword.get(opts, :clock_skew_seconds, @default_clock_skew_seconds)
    issuer = Keyword.get(opts, :issuer, @default_issuer)
    service_url = map_get(payload, "serviceUrl")
    token_service_url = claims["serviceurl"] || claims["serviceUrl"]

    cond do
      claims["iss"] != issuer ->
        {:error, :invalid_issuer}

      not valid_audience?(claims["aud"], app_id) ->
        {:error, :invalid_audience}

      not is_integer(claims["exp"]) or claims["exp"] < now - skew ->
        {:error, :expired_token}

      is_integer(claims["nbf"]) and claims["nbf"] > now + skew ->
        {:error, :token_not_yet_valid}

      not is_binary(service_url) or service_url == "" ->
        {:error, :missing_service_url}

      normalize_url(token_service_url) != normalize_url(service_url) ->
        {:error, :service_url_mismatch}

      true ->
        :ok
    end
  end

  defp valid_audience?(audience, app_id) when is_binary(audience), do: audience == app_id
  defp valid_audience?(audience, app_id) when is_list(audience), do: app_id in audience
  defp valid_audience?(_audience, _app_id), do: false

  defp normalize_url(value) when is_binary(value), do: String.trim_trailing(value, "/")
  defp normalize_url(_value), do: nil

  defp map_get(map, "serviceUrl") when is_map(map),
    do: Map.get(map, "serviceUrl") || Map.get(map, :serviceUrl)

  defp map_get(_map, _key), do: nil

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
