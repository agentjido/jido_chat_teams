defmodule Jido.Chat.Teams.Transport.ReqClientTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Teams.ConversationRef
  alias Jido.Chat.Teams.Transport.ReqClient

  @image_url "https://smba.trafficmanager.net/amer/v3/attachments/0-abc/views/original"
  @download_url "https://contoso-my.sharepoint.com/personal/ada/download.aspx?tempauth=x"
  @bytes <<137, 80, 78, 71, 13, 10, 26, 10>>

  defmodule FakeReq do
    def request(opts) do
      send(Process.get(:test_pid), {:request, opts})

      case Process.get(:responses, []) do
        [response | rest] ->
          Process.put(:responses, rest)
          if is_function(response, 1), do: response.(opts), else: response

        [] ->
          raise "FakeReq has no response"
      end
    end
  end

  setup do
    Process.put(:test_pid, self())
    Process.delete(:responses)
    :ok
  end

  test "gets a token and sends an Activity to the stored service URL" do
    responses([token("token-1"), ok(200, %{"id" => "activity-1"})])

    assert {:ok, %{"id" => "activity-1"}} =
             ReqClient.send_activity(
               credentials(),
               reference(),
               %{"type" => "message", "text" => "hello"},
               req: FakeReq
             )

    assert_receive {:request, token_request}
    assert token_request[:url] =~ "login.microsoftonline.com"
    assert token_request[:form][:client_id] == "app-1"
    assert token_request[:form][:client_secret] == "secret"

    assert_receive {:request, activity_request}

    assert activity_request[:url] ==
             "https://smba.trafficmanager.net/amer/v3/conversations/19%3Athread%40thread.tacv2/activities"

    assert {"authorization", "Bearer token-1"} in activity_request[:headers]
    assert activity_request[:json]["text"] == "hello"
  end

  test "an explicit access token avoids OAuth and encodes reply IDs" do
    responses([ok(200, %{"id" => "reply-1"})])

    assert {:ok, %{"id" => "reply-1"}} =
             ReqClient.reply_to_activity(
               %{},
               reference(),
               "activity/parent",
               %{"type" => "message"},
               req: FakeReq,
               access_token: "direct-token"
             )

    assert_receive {:request, request}
    assert request[:url] =~ "/activities/activity%2Fparent"
    assert {"authorization", "Bearer direct-token"} in request[:headers]
    refute_receive {:request, _}
  end

  test "one unauthorized Activity response gets one new explicit credential token" do
    responses([
      token("old-token"),
      ok(401, %{"error" => "expired"}),
      token("new-token"),
      ok(200, %{"id" => "activity-1"})
    ])

    assert {:ok, %{"id" => "activity-1"}} =
             ReqClient.send_activity(credentials(), reference(), %{"type" => "typing"},
               req: FakeReq
             )

    assert_receive {:request, _token_request}
    assert_receive {:request, first}
    assert {"authorization", "Bearer old-token"} in first[:headers]
    assert_receive {:request, _token_request}
    assert_receive {:request, second}
    assert {"authorization", "Bearer new-token"} in second[:headers]
  end

  test "rate limits are typed and untrusted service URLs make no request" do
    responses([
      {:ok,
       %Req.Response{
         status: 429,
         headers: %{"retry-after" => ["2"]},
         body: %{"error" => "slow down"}
       }}
    ])

    assert {:error, {:rate_limited, 2_000}} =
             ReqClient.send_activity(%{}, reference(), %{"type" => "typing"},
               req: FakeReq,
               access_token: "direct-token"
             )

    assert_receive {:request, _}

    untrusted =
      ConversationRef.new(%{
        conversation_id: "conversation-1",
        service_url: "https://example.test/connector"
      })

    assert {:error, :untrusted_service_url} =
             ReqClient.send_activity(%{}, untrusted, %{"type" => "message"},
               req: FakeReq,
               access_token: "direct-token"
             )

    refute_receive {:request, _}
  end

  test "Bot Connector media uses a bearer token" do
    responses([token("token-1"), ok(200, @bytes)])

    assert {:ok, @bytes} =
             ReqClient.download_media(credentials(), @image_url, req: FakeReq)

    assert_receive {:request, _token_request}
    assert_receive {:request, request}
    assert request[:url] == @image_url
    assert {"authorization", "Bearer token-1"} in request[:headers]
    assert request[:redirect] == false
  end

  test "pre-authenticated SharePoint media never gets a bearer token" do
    responses([ok(200, "pdf-bytes")])

    assert {:ok, "pdf-bytes"} =
             ReqClient.download_media(credentials(), @download_url, req: FakeReq)

    assert_receive {:request, request}
    assert request[:headers] == []
    refute_receive {:request, _}

    responses([ok(401, "expired")])

    assert {:error, {:http_error, 401}} =
             ReqClient.download_media(credentials(), @download_url, req: FakeReq)

    assert_receive {:request, retry_request}
    assert retry_request[:headers] == []
    refute_receive {:request, _}
  end

  test "redirects are reclassified and never send a bearer token to another host" do
    redirect_url = "https://contoso-my.sharepoint.com/personal/ada/download?tempauth=y"

    responses([
      token("token-1"),
      ok(302, "", %{"location" => [redirect_url]}),
      ok(200, "redirected")
    ])

    assert {:ok, "redirected"} =
             ReqClient.download_media(credentials(), @image_url, req: FakeReq)

    assert_receive {:request, _token_request}
    assert_receive {:request, first}
    assert {"authorization", "Bearer token-1"} in first[:headers]
    assert_receive {:request, second}
    assert second[:url] == redirect_url
    assert second[:headers] == []

    responses([ok(302, "", %{"location" => ["https://untrusted.example/download"]})])

    assert {:error, :untrusted_media_url} =
             ReqClient.download_media(credentials(), @download_url, req: FakeReq)

    assert_receive {:request, _}
    refute_receive {:request, _}
  end

  test "media size limits stop streaming and invalid limits make no request" do
    responses([streamed(200, ["abc", "def", "ghi"])])

    assert {:error, :media_too_large} =
             ReqClient.download_media(credentials(), @download_url,
               req: FakeReq,
               max_media_bytes: 4
             )

    assert_receive {:request, _}
    assert_receive {:chunk, "def"}
    refute_receive {:chunk, "ghi"}

    assert {:error, :invalid_max_media_bytes} =
             ReqClient.download_media(credentials(), @download_url,
               req: FakeReq,
               max_media_bytes: 0
             )

    refute_receive {:request, _}
  end

  test "invalid and untrusted media URLs make no request" do
    assert {:error, :untrusted_media_url} =
             ReqClient.download_media(credentials(), "https://bad.example/file", req: FakeReq)

    assert {:error, :invalid_media_url} =
             ReqClient.download_media(
               credentials(),
               "http://smba.trafficmanager.net/amer/file",
               req: FakeReq
             )

    refute_receive {:request, _}
  end

  defp credentials,
    do: %{app_id: "app-1", app_password: "secret"}

  defp reference do
    ConversationRef.new(%{
      conversation_id: "19:thread@thread.tacv2",
      service_url: "https://smba.trafficmanager.net/amer"
    })
  end

  defp streamed(status, chunks) do
    fn opts ->
      response = %Req.Response{status: status, headers: %{}, body: ""}

      {_request, response} =
        Enum.reduce_while(chunks, {nil, response}, fn chunk, acc ->
          send(Process.get(:test_pid), {:chunk, chunk})
          opts[:into].({:data, chunk}, acc)
        end)

      {:ok, response}
    end
  end

  defp token(access_token),
    do: ok(200, %{"access_token" => access_token, "expires_in" => 3_600})

  defp responses(values), do: Process.put(:responses, values)
  defp ok(status, body), do: ok(status, body, %{})

  defp ok(status, body, headers),
    do: {:ok, %Req.Response{status: status, headers: headers, body: body}}
end
