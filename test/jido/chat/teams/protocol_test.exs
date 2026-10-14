defmodule Jido.Chat.Teams.ProtocolTest do
  use ExUnit.Case, async: true
  alias Jido.Chat.Teams.Adapter
  alias Jido.Chat.AdapterTestKit.Factories
  alias Jido.Chat.WebhookRequest

  defmodule Transport do
    @behaviour Jido.Chat.Teams.Transport
    @methods [send_activity: 3, reply_to_activity: 4, update_activity: 4, delete_activity: 3]
    for {name, arity} <- @methods do
      args = Macro.generate_arguments(arity, __MODULE__)
      @impl true
      def unquote(name)(unquote_splicing(args)) do
        args = [unquote_splicing(args)]
        send(List.last(args)[:test_pid], {:provider, unquote(name), args})
        if Process.get(:provider_failure), do: {:error, :timeout}, else: {:ok, %{"id" => "m1"}}
      end
    end
  end

  @matrix Path.join(Mix.Project.deps_paths()[:jido_chat], "docs/migration/adapter-matrix.json")
          |> File.read!()
          |> Jason.decode!()
  @row Enum.find(@matrix["adapters"], &(&1["package"] == "jido_chat_teams"))
  @calls %{
    send_message: [:send_activity],
    post_message: [:send_activity],
    edit_message: [:update_activity],
    delete_message: [:delete_activity],
    start_typing: [:send_activity],
    stream: [:send_activity, :update_activity, :update_activity],
    load_options: [:load_options]
  }
  setup do
    loader = fn request, opts ->
      send(opts[:test_pid], {:provider, :load_options, [request, opts]})
      {:ok, %{options: [%{label: "Ada", value: "u1"}]}}
    end

    {:ok, binding} =
      Jido.Chat.bind(Adapter,
        id: "teams-contract",
        transport: Transport,
        test_pid: self(),
        service_url: "https://private.service.test",
        options_loader: loader,
        app_id: "fixture-app",
        app_password: "private-token",
        verifier: fn _, _ -> :ok end
      )

    %{binding: binding}
  end

  defp request(binding, operation, extra \\ %{}),
    do: Factories.operation_request(binding, operation, extra)

  defp calls do
    receive do
      {:provider, name, _} -> [name | calls()]
    after
      0 -> []
    end
  end

  defp portable(fact) do
    {:ok, json} = Jido.Signal.Serialization.serialize(fact)

    assert {:ok, ^fact} =
             Jido.Signal.Catalog.decode(
               Jido.Signal.Catalog.new!(Jido.Chat.signal_definitions()),
               json
             )

    refute json =~ "private-token"
    refute json =~ "private.service.test"
    refute json =~ "teamsref:v1:"
  end

  for {name, support} <- @row["operation_support"] do
    operation = String.to_atom(name)

    test "#{name} matches frozen #{support} with exact calls and a cached native result", %{
      binding: binding
    } do
      operation = unquote(operation)

      assert Jido.Chat.Adapter.capabilities(Adapter)[operation] ==
               unquote(String.to_atom(support))

      parent = request(binding, operation)
      before = Jido.Signal.to_map(parent)
      assert {:ok, result} = Jido.Chat.execute(binding, parent)

      if unquote(support) == "unsupported" do
        assert result.type == "jido.chat.operation.failed" and
                 result.data["code"] == "unsupported"
      else
        assert result.type == "jido.chat.operation.completed"
      end

      assert calls() == unquote(Map.get(@calls, operation, []))
      assert {:ok, ^result} = Jido.Chat.execute(binding, parent)
      assert calls() == []
      assert Jido.Signal.to_map(parent) == before
      assert Jido.Signal.Context.get(result, "causationid") == parent.id
      assert Jido.Signal.Trace.get(result).trace_id == Jido.Signal.Trace.get(parent).trace_id
      portable(result)
    end
  end

  defp activity(type \\ "message", id \\ "activity-1") do
    %{
      "type" => type,
      "id" => id,
      "serviceUrl" => "https://private.service.test",
      "conversation" => %{"id" => "room-1", "conversationType" => "personal"},
      "recipient" => %{"id" => "bot"},
      "from" => %{"id" => "u1"},
      "text" => "body"
    }
  end

  defp event("MessageReceived"), do: activity()
  defp event("MessageUpdated"), do: activity("messageUpdate") |> Map.delete("text")
  defp event("MessageDeleted"), do: activity("messageDelete")

  defp event(name) when name in ["ReactionAdded", "ReactionRemoved"] do
    key = if name == "ReactionAdded", do: "reactionsAdded", else: "reactionsRemoved"
    Map.put(activity("messageReaction"), key, [%{"type" => "like"}])
  end

  defp event("MembershipChanged"),
    do: Map.put(activity("conversationUpdate"), "membersAdded", [%{"id" => "u2"}])

  defp event("ActionReceived"),
    do:
      activity("invoke")
      |> Map.put("name", "adaptiveCard/action")
      |> Map.put("value", %{"action" => %{"verb" => "approve", "value" => "yes"}})

  defp event("OptionsRequested"),
    do:
      activity("invoke")
      |> Map.put("name", "application/search")
      |> Map.put("value", %{
        "dataset" => "assignee",
        "queryText" => "a",
        "queryOptions" => %{"top" => 12}
      })

  defp event(name), do: activity(name)

  for {name, support} <- @row["event_support"] do
    test "#{name} matches frozen #{support} in verified and injected forms", %{binding: binding} do
      input = event(unquote(name))
      assert {:ok, direct} = Jido.Chat.normalize_event(binding, input)

      assert {:ok, verified} =
               Jido.Chat.normalize_event(binding, WebhookRequest.new(%{payload: input}))

      assert [fact] = verified.signals

      expected =
        if unquote(support) == "unsupported",
          do: "jido.chat.normalization.failed",
          else: Module.concat(Jido.Chat.Signal, unquote(name)).type()

      assert fact.type == expected
      assert hd(direct.signals).data["item_id"] == fact.data["item_id"]
      assert direct.id == verified.id
      portable(fact)
      assert calls() == []
    end
  end

  test "all members and reactions survive in order; absent actors and previous state stay unknown",
       %{binding: binding} do
    members =
      activity("conversationUpdate")
      |> Map.delete("from")
      |> Map.put("membersAdded", [%{"id" => "u2"}, %{"id" => "bot"}])
      |> Map.put("membersRemoved", [%{"id" => "u3"}, %{"id" => "u4"}])

    assert {:ok, %{signals: facts}} = Jido.Chat.normalize_event(binding, members)
    assert Enum.map(facts, & &1.data["participant_id"]) == ["u2", "bot", "u3", "u4"]
    assert Enum.map(facts, & &1.data["transition"]) == ["joined", "joined", "left", "left"]
    assert Enum.map(facts, & &1.data["bot_self"]) == [false, true, false, false]
    assert Enum.all?(facts, &(&1.data["actor_id"] == nil and &1.data["previous"] == nil))
    assert Enum.map(facts, & &1.data["current"]["is_member"]) == [true, true, false, false]
    assert length(Enum.uniq(Enum.map(facts, & &1.data["item_id"]))) == 4

    reactions =
      activity("messageReaction")
      |> Map.put("reactionsAdded", [%{"type" => "like"}, %{"type" => "heart"}])
      |> Map.put("reactionsRemoved", [%{"type" => "laugh"}, %{"type" => "sad"}])

    assert {:ok, %{signals: reactions}} = Jido.Chat.normalize_event(binding, reactions)
    assert Enum.map(reactions, & &1.data["reaction"]) == ["like", "heart", "laugh", "sad"]

    assert Enum.map(reactions, & &1.type) == [
             "jido.chat.reaction.added",
             "jido.chat.reaction.added",
             "jido.chat.reaction.removed",
             "jido.chat.reaction.removed"
           ]

    Enum.each(facts ++ reactions, &portable/1)
  end

  test "malformed list items produce failures while retaining later members and reactions", %{
    binding: binding
  } do
    members = activity("conversationUpdate") |> Map.put("membersAdded", [%{}, %{"id" => "good"}])
    assert {:ok, %{signals: [failure, member]}} = Jido.Chat.normalize_event(binding, members)

    assert failure.type == "jido.chat.normalization.failed" and
             member.data["participant_id"] == "good"

    reactions =
      activity("messageReaction") |> Map.put("reactionsAdded", [%{}, %{"type" => "like"}])

    assert {:ok, %{signals: [failure, reaction]}} = Jido.Chat.normalize_event(binding, reactions)

    assert failure.type == "jido.chat.normalization.failed" and
             reaction.data["reaction"] == "like"
  end

  test "installation facts are explicit bot self evidence", %{binding: binding} do
    for {action, present} <- [{"add", true}, {"remove", false}] do
      input = activity("installationUpdate") |> Map.put("action", action) |> Map.delete("from")
      assert {:ok, %{signals: [fact]}} = Jido.Chat.normalize_event(binding, input)
      assert fact.data["bot_self"] == true and fact.data["actor_id"] == nil
      assert fact.data["current"]["is_member"] == present
    end
  end

  test "zero, many and all four limits validate before acceptance", %{binding: binding} do
    assert {:ok, %{signals: []}} = Jido.Chat.normalize_event(binding, [])
    assert {:ok, %{signals: []}} = Jido.Chat.normalize_event(binding, activity("typing"))

    assert {:ok, %{signals: [one]}} =
             Jido.Chat.normalize_event(binding, activity("message", "second"))

    assert {:ok, %{signals: [first, second]}} =
             Jido.Chat.normalize_event(binding, [activity(), activity("message", "second")])

    assert first.data["message_id"] == "activity-1" and
             second.data["item_id"] == one.data["item_id"]

    batches = [
      Map.put(activity(), "text", String.duplicate("x", 262_145)),
      List.duplicate(activity(), 101),
      List.duplicate(activity("unknown"), 21),
      Enum.map(
        1..6,
        &Map.put(activity("message", "#{&1}"), "text", String.duplicate("x", 200_000))
      )
    ]

    for batch <- batches do
      assert {:error, error} = Jido.Chat.normalize_event(binding, batch)
      assert Adapter.format_webhook_response({:error, error}, []).status == 400
      assert calls() == []
    end
  end

  test "a real JWT is verified before service URL or media controls can be trusted" do
    key = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public} = JOSE.JWK.to_public_map(key)
    public = Map.merge(public, %{"kid" => "key", "alg" => "RS256", "use" => "sig"})
    now = 1_787_137_200

    claims = %{
      "iss" => "https://api.botframework.com",
      "aud" => "fixture-app",
      "exp" => now + 600,
      "nbf" => now - 10,
      "serviceurl" => "https://private.service.test"
    }

    token =
      key
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "key"}, claims)
      |> JOSE.JWS.compact()
      |> elem(1)

    {:ok, binding} =
      Jido.Chat.bind(Adapter,
        id: "jwt",
        transport: Transport,
        test_pid: self(),
        app_id: "fixture-app",
        jwks: [public],
        now: now
      )

    payload =
      activity()
      |> Map.put("attachments", [
        %{"contentType" => "image/png", "contentUrl" => "https://private.service.test/media"}
      ])

    missing = WebhookRequest.new(%{payload: payload})
    assert {:error, _} = Jido.Chat.normalize_event(binding, missing)

    assert :ets.tab2list(binding.options[:reference_store]) == [] and
             :ets.tab2list(binding.resources) == []

    request = %{missing | headers: %{"authorization" => "Bearer " <> token}}
    assert {:ok, %{signals: [fact]}} = Jido.Chat.normalize_event(binding, request)
    portable(fact)
    assert [{"room-1", ^binding, ref}] = :ets.lookup(binding.options[:reference_store], "room-1")
    assert {:ok, %{reference: reference}} = Jido.Chat.resolve_resource(binding, ref)
    assert reference.service_url == "https://private.service.test"

    assert {:ok, result} =
             Jido.Chat.execute(binding, request(binding, :send_message, %{"room_id" => "room-1"}))

    assert result.type == "jido.chat.operation.completed"
    assert_receive {:provider, :send_activity, [^reference, _, _]}
    forged = %{request | payload: Map.put(payload, "serviceUrl", "https://forged.test")}
    assert {:error, _} = Jido.Chat.normalize_event(binding, forged)
    assert [{"room-1", ^binding, ^ref}] = :ets.lookup(binding.options[:reference_store], "room-1")
    assert :ok = Jido.Chat.cancel_resource(binding, ref)

    assert {:ok, %{type: "jido.chat.operation.failed"}} =
             Jido.Chat.execute(
               binding,
               request(binding, :send_message, %{
                 "room_id" => "room-1",
                 "request_id" => "cancelled"
               })
             )

    assert calls() == []
  end

  test "options loading is native, cached and rendered only as a private invoke response", %{
    binding: binding
  } do
    parent = request(binding, :load_options)
    assert {:ok, result} = Jido.Chat.execute(binding, parent)
    assert result.data["result"]["options"] == [%{"label" => "Ada", "value" => "u1"}]
    assert calls() == [:load_options]
    assert {:ok, ^result} = Jido.Chat.execute(binding, parent)
    assert calls() == []
    response = Adapter.format_webhook_response({:ok, result}, [])

    assert response.status == 200 and
             response.body["value"]["results"] == [%{"title" => "Ada", "value" => "u1"}]

    portable(result)
  end

  test "provider failure is typed and cached with one call", %{binding: binding} do
    Process.put(:provider_failure, true)
    parent = request(binding, :send_message)
    assert {:ok, result} = Jido.Chat.execute(binding, parent)
    assert result.data["code"] == "provider_failure"
    assert calls() == [:send_activity]
    assert {:ok, ^result} = Jido.Chat.execute(binding, parent)
    assert calls() == []
  end

  test "cancelled stream has zero enumeration and provider calls", %{binding: binding} do
    stream =
      Stream.map(["hello"], fn text ->
        send(self(), :enumerated)
        text
      end)

    {:ok, ref} = Jido.Chat.put_resource(binding, "stream", stream)
    :ok = Jido.Chat.cancel_resource(binding, ref)
    parent = request(binding, :stream, %{"resource_ref" => ref})
    assert {:ok, result} = Jido.Chat.execute(binding, parent)
    assert result.data["code"] == "resource_cancelled"
    refute_received :enumerated
    assert calls() == []
  end

  test "verified routing controls reject wrong owners and expired resources", %{binding: binding} do
    assert {:ok, _} =
             Jido.Chat.normalize_event(binding, WebhookRequest.new(%{payload: activity()}))

    assert [{_, ^binding, ref}] = :ets.lookup(binding.options[:reference_store], "room-1")
    assert {:ok, private} = Jido.Chat.resolve_resource(binding, ref)

    parent =
      request(binding, :send_message, %{"room_id" => "room-1", "request_id" => "wrong-owner"})

    assert {:error, %{code: :resource_owner_mismatch}} =
             Task.async(fn -> Jido.Chat.execute(binding, parent) end) |> Task.await()

    assert calls() == []
    {:ok, expired} = Jido.Chat.put_resource(binding, "result", private, ttl_ms: 0)
    :ets.insert(binding.options[:reference_store], {"room-1", binding, expired})
    parent = request(binding, :send_message, %{"room_id" => "room-1", "request_id" => "expired"})

    assert {:ok, %{type: "jido.chat.operation.failed", data: %{"code" => "resource_expired"}}} =
             Jido.Chat.execute(binding, parent)

    assert calls() == []
  end

  test "native options timeout is recoverable and a repeated request cannot restart the loader" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    loader = fn _, _ ->
      Agent.update(counter, &(&1 + 1))
      {:error, :timeout}
    end

    {:ok, binding} =
      Jido.Chat.bind(Adapter,
        id: "options-timeout",
        options_loader: loader,
        options_timeout_ms: 10
      )

    parent = request(binding, :load_options)
    assert {:ok, result} = Jido.Chat.execute(binding, parent)
    assert result.type == "jido.chat.operation.failed" and result.data["retryable"] == true
    assert Agent.get(counter, & &1) == 1
    assert {:ok, ^result} = Jido.Chat.execute(binding, parent)
    assert Agent.get(counter, & &1) == 1
    assert Adapter.format_webhook_response({:ok, result}, []).status == 504
    portable(result)
  end

  test "partial update sender and text remain unknown", %{binding: binding} do
    input = activity("messageUpdate") |> Map.delete("from") |> Map.delete("text")
    assert {:ok, %{signals: [fact]}} = Jido.Chat.normalize_event(binding, input)
    assert fact.type == "jido.chat.message.updated" and fact.data["text"] == nil
    refute Map.has_key?(fact.data, "sender")
    portable(fact)
  end
end
