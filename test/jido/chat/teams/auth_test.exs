defmodule Jido.Chat.Teams.AuthTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Client
  alias Jido.Chat.Teams.{Adapter, Auth}

  @tenant_guid "8f2a6c1e-3b4d-4e5f-9a7b-1c2d3e4f5a6b"
  @default_url "https://login.microsoftonline.com/botframework.com/oauth2/v2.0/token"

  defmodule FakeReq do
    def request(opts) do
      send(Process.get(:test_pid), {:request, opts})
      Process.get(:response)
    end
  end

  setup do
    Process.put(:test_pid, self())

    Process.put(
      :response,
      {:ok,
       %Req.Response{
         status: 200,
         headers: %{},
         body: %{"access_token" => "token-1", "expires_in" => "3600"}
       }}
    )

    :ok
  end

  test "explicit credentials select the tenant endpoint and request a token" do
    credentials = %{
      app_id: "app-1",
      app_password: "secret",
      app_tenant_id: @tenant_guid
    }

    assert {:ok, %{access_token: "token-1", expires_in: 3_600}} =
             Auth.fetch_token(credentials, req: FakeReq)

    assert_receive {:request, request}
    assert request[:url] == tenant_url(@tenant_guid)
    assert request[:form][:client_id] == "app-1"
    assert request[:form][:client_secret] == "secret"
    assert request[:redirect] == false
  end

  test "string-key credentials and an explicit token URL work" do
    credentials = %{"app_id" => "app-1", "app_password" => "secret"}

    assert {:ok, _} =
             Auth.fetch_token(credentials,
               req: FakeReq,
               token_url: "https://login.example.test/token"
             )

    assert_receive {:request, request}
    assert request[:url] == "https://login.example.test/token"
  end

  test "application environment does not supply credentials or tenant policy" do
    Application.put_env(:jido_chat_teams, :app_tenant_id, @tenant_guid)
    on_exit(fn -> Application.delete_env(:jido_chat_teams, :app_tenant_id) end)

    assert {:ok, @default_url} = Auth.token_url(%{})
    assert {:error, {:missing_credential, :app_id}} = Auth.fetch_token(%{}, req: FakeReq)
    refute_receive {:request, _}
  end

  test "credential verification reports the provider description" do
    Process.put(
      :response,
      {:ok,
       %Req.Response{
         status: 401,
         headers: %{},
         body: %{"error_description" => "invalid client secret"}
       }}
    )

    client =
      Client.new!(Adapter,
        id: "teams-auth",
        credentials: %{app_id: "app-1", app_password: "bad"},
        config: [req: FakeReq]
      )

    assert {:error, "invalid client secret"} = Auth.verify_credentials(client)
  end

  test "invalid tenant values fail before a request" do
    credentials = %{app_id: "app-1", app_password: "secret", app_tenant_id: "x"}

    assert {:error, {:invalid_credential, :app_tenant_id}} =
             Auth.fetch_token(credentials, req: FakeReq)

    refute_receive {:request, _}
  end

  defp tenant_url(tenant),
    do: "https://login.microsoftonline.com/#{tenant}/oauth2/v2.0/token"
end
