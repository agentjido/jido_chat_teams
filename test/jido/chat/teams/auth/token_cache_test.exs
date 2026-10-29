defmodule Jido.Chat.Teams.Auth.TokenCacheTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Teams.Auth.TokenCache

  @tenant_a "8f2a6c1e-3b4d-4e5f-9a7b-1c2d3e4f5a6b"
  @tenant_b "contoso.onmicrosoft.com"

  defmodule FakeReq do
    def request(opts) do
      send(Process.get(:test_pid), {:request, opts})

      {:ok,
       %Req.Response{
         status: 200,
         headers: %{},
         body: %{"access_token" => "token-for-" <> opts[:url], "expires_in" => 3600}
       }}
    end
  end

  setup do
    TokenCache.clear()
    Process.put(:test_pid, self())
    :ok
  end

  test "keeps a separate token for each app tenant of one app" do
    assert {:ok, token_a} = TokenCache.fetch(opts(app_tenant_id: @tenant_a))
    assert {:ok, token_b} = TokenCache.fetch(opts(app_tenant_id: @tenant_b))

    assert token_a =~ @tenant_a
    assert token_b =~ @tenant_b
    assert_received {:request, _request_a}
    assert_received {:request, _request_b}

    assert {:ok, ^token_a} = TokenCache.fetch(opts(app_tenant_id: @tenant_a))
    refute_received {:request, _request}
  end

  test "invalidates the token cached for an app tenant" do
    assert {:ok, _token} = TokenCache.fetch(opts(app_tenant_id: @tenant_a))
    assert_received {:request, _request}

    assert :ok = TokenCache.invalidate(opts(app_tenant_id: @tenant_a))

    assert {:ok, _token} = TokenCache.fetch(opts(app_tenant_id: @tenant_a))
    assert_received {:request, _request}
  end

  defp opts(extra), do: [req: FakeReq, app_id: "app-1", app_password: "secret"] ++ extra
end
