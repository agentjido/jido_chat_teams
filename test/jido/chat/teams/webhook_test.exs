defmodule Jido.Chat.Teams.WebhookTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Client
  alias Jido.Chat.Teams.{Adapter, Webhook}

  defp client do
    Client.new!(Adapter,
      id: "teams-webhook",
      credentials: %{app_id: "app-1", app_password: "private"},
      config: [issuer: "private-issuer"]
    )
  end

  test "verification passes the payload, headers, explicit credentials, and private policy" do
    verifier = fn payload, headers, credentials, opts ->
      send(self(), {:verified, payload, headers, credentials, opts})
      :ok
    end

    payload = %{"type" => "message"}
    headers = %{"authorization" => "Bearer private-token"}

    assert :ok = Webhook.verify(client(), payload, headers, verifier: verifier, now: 123)

    assert_receive {:verified, ^payload, ^headers, credentials, private}
    assert credentials.app_id == "app-1"
    assert private[:issuer] == "private-issuer"
    assert private[:now] == 123
    refute Keyword.has_key?(private, :verifier)
  end

  test "invalid verifier configuration is rejected" do
    assert {:error, :invalid_verifier} =
             Webhook.verify(client(), %{}, %{}, verifier: {:not, :a_verifier})

    assert {:error, :invalid_verifier} =
             Webhook.verify(client(), %{}, %{}, verifier: NotARealVerifier)
  end

  test "plain invoke responses contain no framework structs" do
    response =
      Webhook.response(
        {:ok,
         %{
           "options" => [
             %{"label" => "Ada", "value" => "user:ada"}
           ]
         }}
      )

    assert response.status == 200

    assert response.body == %{
             "type" => "application/vnd.microsoft.search.searchResponse",
             "value" => %{
               "results" => [%{"title" => "Ada", "value" => "user:ada"}]
             }
           }

    failed = Webhook.response({:error, {:private, "secret-marker"}})
    assert failed.status == 400
    assert failed.body == %{"error" => "invalid_request"}
    refute inspect(failed) =~ "secret-marker"
  end
end
