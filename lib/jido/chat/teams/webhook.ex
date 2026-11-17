defmodule Jido.Chat.Teams.Webhook do
  @moduledoc "Pure Teams webhook admission and response helpers. The host owns HTTP."

  alias Jido.Chat.Client
  alias Jido.Chat.Teams.Auth.JwtVerifier

  @doc "Validates the Bot Connector JWT before an Activity is normalized."
  @spec verify(Client.t(), map(), map() | list(), keyword()) :: :ok | {:error, term()}
  def verify(%Client{credentials: credentials, config: config}, payload, headers, opts \\ []) do
    verifier = opts[:verifier] || JwtVerifier
    private = Keyword.merge(config, Keyword.delete(opts, :verifier))

    cond do
      valid_verifier_module?(verifier) -> verifier.verify(payload, headers, credentials, private)
      is_function(verifier, 4) -> verifier.(payload, headers, credentials, private)
      true -> {:error, :invalid_verifier}
    end
  end

  @doc "Builds a plain Teams invoke response."
  @spec response(term()) :: map()
  def response({:ok, %{"options" => options}}) when is_list(options) do
    %{
      status: 200,
      headers: %{"content-type" => "application/json"},
      body: %{
        "type" => "application/vnd.microsoft.search.searchResponse",
        "value" => %{
          "results" => Enum.map(options, &%{"title" => &1["label"], "value" => &1["value"]})
        }
      }
    }
  end

  def response({:ok, body}),
    do: %{status: 200, headers: %{"content-type" => "application/json"}, body: body || %{}}

  def response({:error, _reason}),
    do: %{
      status: 400,
      headers: %{"content-type" => "application/json"},
      body: %{"error" => "invalid_request"}
    }

  defp valid_verifier_module?(verifier) when is_atom(verifier),
    do: Code.ensure_loaded?(verifier) and function_exported?(verifier, :verify, 4)

  defp valid_verifier_module?(_), do: false
end
