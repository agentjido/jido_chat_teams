defmodule Jido.Chat.Teams.Transport do
  @moduledoc """
  Transport contract for Microsoft Bot Connector activity operations.
  """

  alias Jido.Chat.Teams.ConversationRef

  @type api_result :: {:ok, map()} | {:error, term()}

  @callback send_activity(map(), ConversationRef.t(), map(), keyword()) :: api_result()

  @callback reply_to_activity(map(), ConversationRef.t(), String.t(), map(), keyword()) ::
              api_result()

  @callback update_activity(map(), ConversationRef.t(), String.t(), map(), keyword()) ::
              api_result()

  @callback delete_activity(map(), ConversationRef.t(), String.t(), keyword()) ::
              {:ok, map() | boolean()} | {:error, term()}

  @callback download_media(map(), url :: String.t(), keyword()) ::
              {:ok, binary()} | {:error, term()}
end
