defmodule Jido.Chat.Teams.AuthTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Teams.Auth

  @tenant_guid "8f2a6c1e-3b4d-4e5f-9a7b-1c2d3e4f5a6b"
  @default_url "https://login.microsoftonline.com/botframework.com/oauth2/v2.0/token"

  defmodule FakeReq do
    def request(opts) do
      send(Process.get(:test_pid), {:request, opts})

      {:ok,
       %Req.Response{
         status: 200,
         headers: %{},
         body: %{"access_token" => "token-1", "expires_in" => 3600}
       }}
    end
  end

  defp credentials(opts), do: [req: FakeReq, app_id: "app-1", app_password: "secret"] ++ opts

  defp tenant_url(tenant), do: "https://login.microsoftonline.com/#{tenant}/oauth2/v2.0/token"

  setup do
    Process.put(:test_pid, self())
    :ok
  end

  describe "token_url/1" do
    test "keeps an explicit token URL ahead of the app tenant" do
      assert {:ok, "https://login.example.test/token"} =
               Auth.token_url(
                 token_url: "https://login.example.test/token",
                 app_tenant_id: @tenant_guid
               )
    end

    test "reads the app tenant from its alias and from nested credentials" do
      expected = {:ok, tenant_url(@tenant_guid)}

      assert expected == Auth.token_url(microsoft_app_tenant_id: @tenant_guid)
      assert expected == Auth.token_url(credentials: %{app_tenant_id: @tenant_guid})
      assert expected == Auth.token_url(credentials: %{"microsoft_app_tenant_id" => @tenant_guid})
    end

    test "reads the app tenant from the application environment" do
      Application.put_env(:jido_chat_teams, :app_tenant_id, @tenant_guid)
      on_exit(fn -> Application.delete_env(:jido_chat_teams, :app_tenant_id) end)

      assert {:ok, tenant_url(@tenant_guid)} == Auth.token_url([])
    end

    test "does not treat a conversation tenant_id as the app tenant" do
      assert {:ok, @default_url} = Auth.token_url(tenant_id: @tenant_guid)
    end
  end

  describe "fetch_token/1" do
    test "requests the token from the app tenant endpoint" do
      assert {:ok, %{access_token: "token-1", expires_in: 3600}} =
               Auth.fetch_token(credentials(app_tenant_id: @tenant_guid))

      assert_received {:request, request}
      assert request[:url] == tenant_url(@tenant_guid)
      assert request[:form][:client_id] == "app-1"
    end

    test "keeps the multi-tenant endpoint without an app tenant" do
      assert {:ok, %{access_token: "token-1"}} = Auth.fetch_token(credentials([]))

      assert_received {:request, request}
      assert request[:url] == @default_url
    end
  end
end
