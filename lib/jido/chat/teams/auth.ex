defmodule Jido.Chat.Teams.Auth do
  @moduledoc """
  Microsoft Bot Connector OAuth token acquisition.

  A multi-tenant bot gets tokens from the `botframework.com` endpoint. A
  single-tenant bot sets `app_tenant_id` to its Microsoft Entra tenant, and the
  adapter uses that tenant's endpoint. See `token_url/1`.
  """

  @default_token_url "https://login.microsoftonline.com/botframework.com/oauth2/v2.0/token"
  @default_scope "https://api.botframework.com/.default"
  # tenant id is a GUID or DNS domain, the length is soft validation.
  @app_tenant_id_length 3..253

  defguardp is_app_tenant_id(value)
            when is_binary(value) and byte_size(value) in @app_tenant_id_length

  @doc "Requests a Bot Connector access token with client credentials."
  @spec fetch_token(keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_token(opts) when is_list(opts) do
    with {:ok, app_id} <- credential(opts, :app_id),
         {:ok, app_password} <- credential(opts, :app_password),
         {:ok, token_url} <- token_url(opts) do
      req = Keyword.get(opts, :req, Req)
      scope = Keyword.get(opts, :scope, @default_scope)

      request_opts = [
        method: :post,
        url: token_url,
        form: [
          grant_type: "client_credentials",
          client_id: app_id,
          client_secret: app_password,
          scope: scope
        ],
        retry: false,
        redirect: false
      ]

      case req.request(request_opts) do
        {:ok, %Req.Response{status: status, body: body}}
        when status in 200..299 and is_map(body) ->
          case body["access_token"] || body[:access_token] do
            token when is_binary(token) and token != "" ->
              {:ok,
               %{
                 access_token: token,
                 expires_in: normalize_expires_in(body["expires_in"] || body[:expires_in]),
                 token_type: body["token_type"] || body[:token_type] || "Bearer"
               }}

            _other ->
              {:error, :missing_access_token}
          end

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:oauth_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Returns the OAuth token URL: `:token_url` if given, else the `:app_tenant_id`
  endpoint (a GUID or domain), else the multi-tenant `botframework.com` endpoint.
  The conversation `:tenant_id` is ignored.
  """
  @spec token_url(keyword()) :: {:ok, String.t()} | {:error, term()}
  def token_url(opts) when is_list(opts) do
    case Keyword.fetch(opts, :token_url) do
      {:ok, token_url} -> {:ok, token_url}
      :error -> opts |> credential_value(:app_tenant_id) |> tenant_token_url()
    end
  end

  @doc "Returns an adapter credential from direct or nested options."
  @spec credential(keyword(), atom()) :: {:ok, String.t()} | {:error, term()}
  def credential(opts, key) when is_list(opts) do
    case credential_value(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_credential, key}}
    end
  end

  defp credential_value(opts, key) do
    aliases = credential_aliases(key)

    Enum.find_value(aliases, fn alias_key -> Keyword.get(opts, alias_key) end) ||
      nested_credential(Keyword.get(opts, :credentials), aliases) ||
      application_credential(aliases)
  end

  defp tenant_token_url(nil), do: {:ok, @default_token_url}

  defp tenant_token_url(tenant_id) when is_app_tenant_id(tenant_id),
    do: {:ok, "https://login.microsoftonline.com/#{tenant_id}/oauth2/v2.0/token"}

  defp tenant_token_url(_tenant_id), do: {:error, {:invalid_credential, :app_tenant_id}}

  defp nested_credential(credentials, aliases) when is_map(credentials) do
    Enum.find_value(aliases, fn key ->
      Map.get(credentials, key) || Map.get(credentials, Atom.to_string(key))
    end)
  end

  defp nested_credential(_credentials, _aliases), do: nil

  defp application_credential(aliases) do
    Enum.find_value(aliases, &Application.get_env(:jido_chat_teams, &1))
  end

  defp credential_aliases(:app_id), do: [:app_id, :microsoft_app_id, :client_id]

  defp credential_aliases(:app_password),
    do: [:app_password, :microsoft_app_password, :client_secret]

  defp credential_aliases(:app_tenant_id), do: [:app_tenant_id, :microsoft_app_tenant_id]

  defp credential_aliases(key), do: [key]

  defp normalize_expires_in(value) when is_integer(value) and value > 0, do: value

  defp normalize_expires_in(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> 3600
    end
  end

  defp normalize_expires_in(_value), do: 3600
end
