defmodule Jido.Chat.Teams.Adapter do
  @moduledoc "Stateless Microsoft Teams adapter for Jido Chat."
  use Jido.Chat.Adapter

  @native [:send_message, :edit_message, :delete_message, :start_typing, :fetch_metadata]

  @impl true
  def channel_type, do: :teams

  @impl true
  def default_transport, do: Jido.Chat.Teams.Transport.ReqClient

  @impl true
  def event_definitions, do: Jido.Chat.Teams.event_definitions()

  @impl true
  def capabilities do
    Map.new(Jido.Chat.Operations.Definitions.all(), fn {_, {_, operation, _, _, _}} ->
      {operation, if(operation in @native, do: :native, else: :unsupported)}
    end)
  end

  @impl true
  def invoke(client, request, opts) do
    case Jido.Chat.Operations.Definitions.lookup(request.type) do
      {_, operation, _, _, _} ->
        Jido.Chat.Teams.Operations.invoke(operation, client, request, opts)

      _ ->
        {:error, {:not_attempted, :unsupported}}
    end
  end

  @impl true
  def normalize(client, input, _opts), do: Jido.Chat.Teams.Normalizer.normalize(client, input)
end
