defmodule Jido.Chat.Teams.AdapterTest do
  use Jido.Chat.AdapterTestKit, adapter: Jido.Chat.Teams.Adapter, async: true

  alias Jido.Chat
  alias Jido.Chat.Adapter, as: ChatAdapter
  alias Jido.Chat.Client
  alias Jido.Chat.Teams
  alias Jido.Chat.Teams.{Adapter, ConversationRef, Operations, TestTransport}
  alias Jido.Chat.Teams.Transport.ReqClient

  defmodule OptionsLoader do
    @moduledoc false

    def load(data, opts, prefix) do
      send(opts[:test_pid], {:mfa_loader, data["query"], prefix})
      [{"MFA", "mfa"}]
    end
  end

  defp client(opts \\ []) do
    Client.new!(Adapter,
      id: "teams-#{System.unique_integer([:positive])}",
      credentials:
        Keyword.get(opts, :credentials, %{
          app_id: "app-1",
          app_password: "secret-1",
          app_tenant_id: "tenant-1"
        }),
      config: [test_pid: self(), marker: :private],
      transport: TestTransport
    )
  end

  defp room_id do
    ConversationRef.encode(%{
      conversation_id: "19:thread@thread.tacv2",
      service_url: "https://smba.trafficmanager.net/amer",
      tenant_id: "tenant-1",
      scope: :channel,
      team_id: "team-1",
      channel_id: "channel-1"
    })
  end

  test "client discovery is local and credentials stay private" do
    value = client()

    assert Adapter.default_transport() == ReqClient
    assert Teams.adapter() == Adapter
    assert Teams.webhook() == Teams.Webhook
    assert :ok = ChatAdapter.validate_capabilities(Adapter)
    refute inspect(value) =~ "secret-1"
  end

  test "message, reply, stream, edit, delete, and typing use explicit credentials" do
    value = client()
    room_id = room_id()

    assert {:ok, sent} =
             Chat.send_text(value, room_id, "hello",
               keyboard: %{
                 "rows" => [
                   [
                     %{"text" => "Approve", "value" => "approve"},
                     %{"text" => "Docs", "url" => "https://example.test/docs"}
                   ]
                 ]
               }
             )

    assert sent.data["result"]["id"] == "activity-sent"

    assert_receive {:send_activity, credentials, reference, activity, private}
    assert credentials.app_id == "app-1"
    assert reference.conversation_id == "19:thread@thread.tacv2"
    assert activity["text"] == "hello"
    assert activity["textFormat"] == "markdown"
    assert [%{"content" => %{"actions" => [submit, link]}}] = activity["attachments"]
    assert submit["type"] == "Action.Submit"
    assert link["type"] == "Action.OpenUrl"
    assert private[:marker] == :private
    refute Keyword.has_key?(private, :app_password)

    assert {:ok, _} = Chat.send_text(value, room_id, "reply", reply_to_id: "activity-0")
    assert_receive {:reply_to_activity, _, ^reference, "activity-0", %{"text" => "reply"}, _}

    assert {:ok, _} = Chat.stream_text(value, room_id, ["a", "b"])
    assert_receive {:send_activity, _, ^reference, %{"text" => "ab"}, _}

    assert {:ok, _} = Chat.edit_message(value, room_id, "activity-1", "updated")
    assert_receive {:update_activity, _, ^reference, "activity-1", %{"text" => "updated"}, _}

    assert {:ok, deleted} = Chat.delete_message(value, room_id, "activity-1")
    assert deleted.data["result"] == %{"acknowledged" => true}
    assert_receive {:delete_activity, _, ^reference, "activity-1", _}

    assert {:ok, typed} = Chat.start_typing(value, room_id)
    assert typed.data["result"] == %{"acknowledged" => true}
    assert_receive {:send_activity, _, ^reference, %{"type" => "typing"}, _}
  end

  test "local metadata, thread, subject, and options need no provider credentials" do
    value = client(credentials: %{})
    room_id = room_id()

    assert {:ok, metadata} = Chat.fetch_metadata(value, room_id)

    assert metadata.data["result"] == %{
             "id" => room_id,
             "kind" => "channel",
             "name" => "channel-1"
           }

    thread = operation_request(value, :fetch_thread, %{"room_id" => room_id})
    assert {:ok, thread_result} = Chat.execute(value, thread)
    assert thread_result.data["result"]["delivery_room_ref"] == "19:thread@thread.tacv2"

    subject = operation_request(value, :fetch_subject, %{"room_id" => room_id})
    assert {:ok, subject_result} = Chat.execute(value, subject)
    assert subject_result.data["result"]["kind"] == "conversation"

    options = operation_request(value, :load_options)

    assert {:ok, options_result} =
             Chat.execute(value, options,
               options: [
                 options_loader: fn _ ->
                   [%{label: "Ada", value: "user:ada"}, {"Grace", "user:grace"}]
                 end
               ]
             )

    assert options_result.data["result"] == %{
             "options" => [
               %{"label" => "Ada", "value" => "user:ada"},
               %{"label" => "Grace", "value" => "user:grace"}
             ],
             "complete" => true
           }

    assert {:ok, mfa_result} =
             Chat.execute(value, options,
               options: [options_loader: {OptionsLoader, :load, ["prefix"]}]
             )

    assert mfa_result.data["result"]["options"] == [
             %{"label" => "MFA", "value" => "mfa"}
           ]

    assert_receive {:mfa_loader, "a", "prefix"}

    assert {:ok, atom_map_result} =
             Chat.execute(value, options,
               options: [
                 options_loader: fn _ ->
                   {:ok, %{options: [%{label: "Atom", value: "atom"}], complete: false}}
                 end
               ]
             )

    assert atom_map_result.data["result"] == %{
             "options" => [%{"label" => "Atom", "value" => "atom"}],
             "complete" => false
           }
  end

  test "options loading is bounded and leaves no late result in the caller mailbox" do
    value = client(credentials: %{})
    request = operation_request(value, :load_options)
    test_pid = self()

    loader = fn _ ->
      send(test_pid, {:loader_started, self()})
      receive do: (:release -> [%{"label" => "Late", "value" => "late"}])
    end

    assert {:error, :options_timeout} =
             Operations.invoke(:load_options, value, request,
               options_loader: loader,
               options_timeout_ms: 5
             )

    assert_receive {:loader_started, loader_pid}
    monitor = Process.monitor(loader_pid)
    assert_receive {:DOWN, ^monitor, :process, ^loader_pid, _}
    refute_receive {_reference, _value}

    assert {:error, :invalid_options_timeout} =
             Operations.invoke(:load_options, value, request,
               options_loader: fn _ -> [] end,
               options_timeout_ms: -1
             )
  end

  test "client-scoped media downloads return canonical base64 content" do
    value = client()

    reference = %{
      "client_id" => value.id,
      "kind" => "media",
      "id" => "https://smba.trafficmanager.net/amer/v3/attachments/1"
    }

    assert {:ok, result} = Chat.download_file(value, reference)
    assert result.data["result"]["content_base64"] == Base.encode64("media-bytes")
    assert_receive {:download_media, credentials, reference_url, _}
    assert credentials.app_password == "secret-1"
    assert reference_url == reference["id"]

    wrong_client = Map.put(reference, "client_id", "another-client")
    assert {:error, _} = Chat.download_file(value, wrong_client)
    refute_receive {:download_media, _, _, _}

    signed = Map.put(reference, "id", reference["id"] <> "?token=private")
    assert {:error, _} = Chat.download_file(value, signed)
    refute_receive {:download_media, _, _, _}
  end

  test "string-key credentials work and unsupported operations do not attempt provider I/O" do
    value = client(credentials: %{"app_id" => "app-1", "app_password" => "secret-1"})

    assert {:ok, _} = Chat.send_text(value, room_id(), "hello")
    assert_receive {:send_activity, %{"app_id" => "app-1"}, _, _, _}

    no_credentials = client(credentials: %{})
    request = operation_request(no_credentials, :send_message, %{"room_id" => room_id()})

    assert {:error, {:not_attempted, :missing_app_credentials}} =
             Operations.invoke(:send_message, no_credentials, request, [])

    assert {:error, {:not_attempted, :unsupported}} =
             Operations.invoke(:send_file, no_credentials, request, [])

    refute_receive {:send_activity, _, _, _, _}
  end

  test "HTML is an explicit unsupported format" do
    assert {:error, _} = Chat.send_text(client(), room_id(), "hello", format: :html)
    refute_receive {:send_activity, _, _, _, _}
  end
end
