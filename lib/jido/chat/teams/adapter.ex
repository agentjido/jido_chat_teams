defmodule Jido.Chat.Teams.Adapter do
  @moduledoc "Stateless Microsoft Teams adapter for native Chat request and result Signals."

  use Jido.Chat.Adapter

  alias Jido.Chat.Operations.Definitions
  alias Jido.Chat.Teams
  alias Jido.Chat.Teams.{Normalizer, Operations}
  alias Jido.Chat.Teams.Transport.ReqClient

  @native ~w(stream_text send_message edit_message delete_message start_typing fetch_metadata fetch_thread fetch_subject download_file load_options)a

  @impl true
  def channel_type, do: :teams

  @impl true
  def default_transport, do: ReqClient

  @impl true
  def operations, do: Teams.operations()

  @impl true
  def event_definitions, do: Teams.event_definitions()

  @impl true
  def capabilities do
    Map.new(Definitions.all(), fn {_, {_, operation, _, _, _}} ->
      {operation, if(operation in @native, do: :native, else: :unsupported)}
    end)
  end

  @impl true
  def invoke(client, request, opts) do
    case Definitions.lookup(request.type) do
      {_, operation, _, _, _} -> Operations.invoke(operation, client, request, opts)
      _ -> {:error, {:not_attempted, :unsupported}}
    end
  end

  @impl true
  def normalize(client, input, _opts), do: Normalizer.normalize(client, input)
end
