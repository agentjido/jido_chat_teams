defmodule Jido.Chat.Teams.Transport do
  @moduledoc """
  Transport contract for Microsoft Bot Connector activity operations.
  """

  alias Jido.Chat.Teams.ConversationRef

  @type api_result :: {:ok, map()} | {:error, term()}

  @callback send_activity(ConversationRef.t(), map(), keyword()) :: api_result()

  @callback reply_to_activity(ConversationRef.t(), String.t(), map(), keyword()) :: api_result()

  @callback update_activity(ConversationRef.t(), String.t(), map(), keyword()) :: api_result()

  @callback delete_activity(ConversationRef.t(), String.t(), keyword()) ::
              {:ok, map() | boolean()} | {:error, term()}

  @callback download_media(url :: String.t(), keyword()) :: {:ok, binary()} | {:error, term()}

  @optional_callbacks download_media: 2
end
