defmodule Jido.Chat.Teams.Auth do
  @moduledoc """
  Microsoft Bot Connector OAuth token acquisition.
  """

  @default_token_url "https://login.microsoftonline.com/botframework.com/oauth2/v2.0/token"
  @default_scope "https://api.botframework.com/.default"

  @doc "Requests a Bot Connector access token with client credentials."
  @spec fetch_token(keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_token(opts) when is_list(opts) do
    with {:ok, app_id} <- credential(opts, :app_id),
         {:ok, app_password} <- credential(opts, :app_password) do
      req = Keyword.get(opts, :req, Req)
      token_url = Keyword.get(opts, :token_url, @default_token_url)
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

  @doc "Returns an adapter credential from direct or nested options."
  @spec credential(keyword(), atom()) :: {:ok, String.t()} | {:error, term()}
  def credential(opts, key) when is_list(opts) do
    aliases = credential_aliases(key)

    value =
      Enum.find_value(aliases, fn alias_key -> Keyword.get(opts, alias_key) end) ||
        nested_credential(Keyword.get(opts, :credentials), aliases) ||
        application_credential(aliases)

    case value do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_credential, key}}
    end
  end

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
