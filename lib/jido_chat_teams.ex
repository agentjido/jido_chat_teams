defmodule Jido.Chat.Teams do
  @moduledoc """
  Microsoft Teams adapter support for `Jido.Chat`.

  Use `Jido.Chat.Teams.Adapter` for normalized inbound and outbound operations.
  """

  alias Jido.Chat.Teams.Adapter

  @doc "Returns the canonical adapter module."
  @spec adapter() :: module()
  def adapter, do: Adapter

  @doc "Returns the incoming facts normalized by Teams."
  def event_definitions do
    [
      Jido.Chat.Signal.MessageReceived,
      Jido.Chat.Signal.MessageUpdated,
      Jido.Chat.Signal.NormalizationFailed
    ]
  end
end
