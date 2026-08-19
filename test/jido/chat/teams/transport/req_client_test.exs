defmodule Jido.Chat.Teams.Transport.ReqClientTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Teams.Auth.TokenCache
  alias Jido.Chat.Teams.ConversationRef
  alias Jido.Chat.Teams.Transport.ReqClient

  defmodule FakeReq do
    def request(opts) do
      send(Process.get(:test_pid), {:request, opts})

      case Process.get(:responses, []) do
        [response | rest] ->
          Process.put(:responses, rest)
          response

        [] ->
          raise "FakeReq has no response"
      end
    end
  end

  setup do
    TokenCache.clear()
    Process.put(:test_pid, self())
    Process.delete(:responses)
    :ok
  end

  test "gets a token and sends an activity to the stored service URL" do
    responses([
      ok(200, %{"access_token" => "token-1", "expires_in" => 3600}),
      ok(200, %{"id" => "activity-1"})
    ])

    assert {:ok, %{"id" => "activity-1"}} =
             ReqClient.send_activity(reference(), %{"type" => "message", "text" => "hello"},
               req: FakeReq,
               app_id: "app-1",
               app_password: "secret"
             )

    assert_received {:request, token_request}
    assert token_request[:url] =~ "login.microsoftonline.com"
    assert token_request[:form][:client_id] == "app-1"
    assert token_request[:form][:client_secret] == "secret"

    assert_received {:request, activity_request}

    assert activity_request[:url] ==
             "https://smba.trafficmanager.net/amer/v3/conversations/19%3Athread%40thread.tacv2/activities"

    assert {"authorization", "Bearer token-1"} in activity_request[:headers]
    assert activity_request[:json] == %{"type" => "message", "text" => "hello"}
  end

  test "uses an explicit access token without an OAuth request" do
    responses([ok(200, %{"id" => "reply-1"})])

    assert {:ok, %{"id" => "reply-1"}} =
             ReqClient.reply_to_activity(
               reference(),
               "activity/parent",
               %{"type" => "message"},
               req: FakeReq,
               access_token: "direct-token"
             )

    assert_received {:request, request}
    assert request[:url] =~ "/activities/activity%2Fparent"
    assert {"authorization", "Bearer direct-token"} in request[:headers]
    refute_received {:request, _other}
  end

  test "returns the Microsoft retry interval for a rate limit" do
    responses([
      {:ok,
       %Req.Response{
         status: 429,
         headers: %{"retry-after" => ["2"]},
         body: %{"error" => "slow down"}
       }}
    ])

    assert {:error, {:rate_limited, 2_000}} =
             ReqClient.send_activity(reference(), %{"type" => "typing"},
               req: FakeReq,
               access_token: "direct-token"
             )
  end

  test "rejects a service URL that is not trusted" do
    reference =
      ConversationRef.new(%{
        conversation_id: "conversation-1",
        service_url: "https://example.test/connector"
      })

    assert {:error, :untrusted_service_url} =
             ReqClient.send_activity(reference, %{"type" => "message"},
               req: FakeReq,
               access_token: "direct-token"
             )

    refute_received {:request, _opts}
  end

  defp reference do
    ConversationRef.new(%{
      conversation_id: "19:thread@thread.tacv2",
      service_url: "https://smba.trafficmanager.net/amer"
    })
  end

  defp responses(values), do: Process.put(:responses, values)
  defp ok(status, body), do: {:ok, %Req.Response{status: status, headers: %{}, body: body}}
end
