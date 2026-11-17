defmodule Jido.Chat.Teams do
  @moduledoc """
  Microsoft Teams adapter support for `Jido.Chat`.

  Use `Jido.Chat.Teams.Adapter` for typed provider operations and normalization.
  The host owns the HTTP endpoint and calls `Jido.Chat.Teams.Webhook` before
  admitting an Activity.
  """

  alias Jido.Chat.Teams.{Adapter, Webhook}

  @doc "Returns the canonical adapter module."
  @spec adapter() :: module()
  def adapter, do: Adapter

  @doc "Returns the host-owned Teams webhook helper module."
  @spec webhook() :: module()
  def webhook, do: Webhook

  @doc "Returns provider extension request and Action pairs."
  @spec operations() :: []
  def operations, do: []

  @doc "Returns incoming facts normalized by Teams."
  @spec event_definitions() :: [module()]
  def event_definitions do
    [
      Jido.Chat.Signal.MessageReceived,
      Jido.Chat.Signal.MessageUpdated,
      Jido.Chat.Signal.MessageDeleted,
      Jido.Chat.Signal.ReactionAdded,
      Jido.Chat.Signal.ReactionRemoved,
      Jido.Chat.Signal.ActionReceived,
      Jido.Chat.Signal.OptionsRequested,
      Jido.Chat.Signal.NormalizationFailed
    ]
  end
end
