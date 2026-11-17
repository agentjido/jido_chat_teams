defmodule Jido.Chat.Teams.Auth do
  @moduledoc "Microsoft Bot Connector OAuth with explicit Client credentials."

  @default_token_url "https://login.microsoftonline.com/botframework.com/oauth2/v2.0/token"
  @default_scope "https://api.botframework.com/.default"
  @tenant_length 3..253

  @doc "Requests one Bot Connector access token."
  @spec fetch_token(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_token(credentials, opts \\ []) when is_map(credentials) and is_list(opts) do
    with {:ok, app_id} <- credential(credentials, :app_id),
         {:ok, app_password} <- credential(credentials, :app_password),
         {:ok, token_url} <- token_url(credentials, opts) do
      opts
      |> Keyword.get(:req, Req)
      |> then(& &1.request(token_request(token_url, app_id, app_password, opts)))
      |> token_response()
    end
  end

  @doc "Checks app credentials without sending an Activity."
  @spec verify_credentials(Jido.Chat.Client.t(), keyword()) :: :ok | {:error, term()}
  def verify_credentials(%Jido.Chat.Client{credentials: credentials, config: config}, opts \\ []) do
    case fetch_token(credentials, Keyword.merge(config, opts)) do
      {:ok, _} -> :ok
      {:error, {:oauth_error, _, %{"error_description" => description}}} -> {:error, description}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the configured single-tenant or multi-tenant OAuth URL."
  @spec token_url(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def token_url(credentials, opts \\ []) when is_map(credentials) and is_list(opts) do
    case opts[:token_url] do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> tenant_url(credentials[:app_tenant_id] || credentials["app_tenant_id"])
    end
  end

  @doc "Returns a required string credential from a Client credential map."
  @spec credential(map(), atom()) :: {:ok, String.t()} | {:error, term()}
  def credential(credentials, key) when is_map(credentials) do
    case credentials[key] || credentials[Atom.to_string(key)] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_credential, key}}
    end
  end

  defp tenant_url(nil), do: {:ok, @default_token_url}

  defp tenant_url(tenant) when is_binary(tenant) and byte_size(tenant) in @tenant_length,
    do: {:ok, "https://login.microsoftonline.com/#{tenant}/oauth2/v2.0/token"}

  defp tenant_url(_), do: {:error, {:invalid_credential, :app_tenant_id}}

  defp token_request(token_url, app_id, app_password, opts) do
    [
      method: :post,
      url: token_url,
      form: [
        grant_type: "client_credentials",
        client_id: app_id,
        client_secret: app_password,
        scope: Keyword.get(opts, :scope, @default_scope)
      ],
      retry: false,
      redirect: false
    ]
  end

  defp token_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 and is_map(body) do
    token_value(body["access_token"] || body[:access_token], body)
  end

  defp token_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:oauth_error, status, body}}

  defp token_response({:error, reason}), do: {:error, reason}

  defp token_value(token, body) when is_binary(token) and token != "" do
    {:ok,
     %{
       access_token: token,
       expires_in: expires_in(body["expires_in"] || body[:expires_in]),
       token_type: body["token_type"] || body[:token_type] || "Bearer"
     }}
  end

  defp token_value(_, _), do: {:error, :missing_access_token}

  defp expires_in(value) when is_integer(value) and value > 0, do: value

  defp expires_in(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> 3_600
    end
  end

  defp expires_in(_), do: 3_600
end
