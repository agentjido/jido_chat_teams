defmodule Jido.Chat.Teams do
  @moduledoc """
  Microsoft Teams adapter support for `Jido.Chat`.

  Use `Jido.Chat.Teams.Adapter` for normalized inbound and outbound operations.
  """

  alias Jido.Chat.Teams.Adapter

  @doc "Returns the canonical adapter module."
  @spec adapter() :: module()
  def adapter, do: Adapter
end
