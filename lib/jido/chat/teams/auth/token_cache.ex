defmodule Jido.Chat.Teams.Auth.TokenCache do
  @moduledoc """
  Small process-independent cache for Bot Connector OAuth access tokens.
  """

  alias Jido.Chat.Teams.Auth

  @table :jido_chat_teams_token_cache
  @early_refresh_seconds 60

  @doc "Returns an explicit token or a cached client-credentials token."
  @spec fetch(keyword()) :: {:ok, String.t()} | {:error, term()}
  def fetch(opts) when is_list(opts) do
    case Keyword.get(opts, :access_token) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _other ->
        fetch_cached(opts)
    end
  end

  @doc "Removes the cached token for the supplied options."
  @spec invalidate(keyword()) :: :ok
  def invalidate(opts) when is_list(opts) do
    ensure_table()

    with {:ok, token_url} <- Auth.token_url(opts) do
      :ets.delete(@table, cache_key(opts, token_url))
    end

    :ok
  end

  @doc false
  def clear do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp fetch_cached(opts) do
    ensure_table()

    with {:ok, token_url} <- Auth.token_url(opts) do
      lookup_or_fetch(opts, cache_key(opts, token_url))
    end
  end

  defp lookup_or_fetch(opts, key) do
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, token, expires_at}] when expires_at > now + @early_refresh_seconds ->
        {:ok, token}

      _other ->
        with {:ok, result} <- Auth.fetch_token(opts) do
          expires_at = now + result.expires_in
          true = :ets.insert(@table, {key, result.access_token, expires_at})
          {:ok, result.access_token}
        end
    end
  end

  # The resolved URL keeps tokens for different app tenants apart.
  defp cache_key(opts, token_url) do
    app_id = credential_value(opts, [:app_id, :microsoft_app_id, :client_id])
    scope = Keyword.get(opts, :scope, :default)
    {app_id, token_url, scope}
  end

  defp credential_value(opts, keys) do
    Enum.find_value(keys, &Keyword.get(opts, &1)) ||
      nested_value(Keyword.get(opts, :credentials), keys)
  end

  defp nested_value(credentials, keys) when is_map(credentials) do
    Enum.find_value(keys, fn key ->
      Map.get(credentials, key) || Map.get(credentials, Atom.to_string(key))
    end)
  end

  defp nested_value(_credentials, _keys), do: nil

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      table ->
        table
    end
  end
end
