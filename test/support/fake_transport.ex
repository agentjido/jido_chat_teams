defmodule Jido.Chat.Teams.TestTransport do
  @moduledoc false

  @behaviour Jido.Chat.Teams.Transport

  def send_activity(credentials, reference, activity, opts) do
    report(opts, {:send_activity, credentials, reference, activity, opts})
    {:ok, %{"id" => "activity-sent"}}
  end

  def reply_to_activity(credentials, reference, activity_id, activity, opts) do
    report(opts, {:reply_to_activity, credentials, reference, activity_id, activity, opts})
    {:ok, %{"id" => "activity-reply"}}
  end

  def update_activity(credentials, reference, activity_id, activity, opts) do
    report(opts, {:update_activity, credentials, reference, activity_id, activity, opts})
    {:ok, %{"id" => activity_id}}
  end

  def delete_activity(credentials, reference, activity_id, opts) do
    report(opts, {:delete_activity, credentials, reference, activity_id, opts})
    {:ok, true}
  end

  def download_media(credentials, url, opts) do
    report(opts, {:download_media, credentials, url, opts})
    {:ok, "media-bytes"}
  end

  defp report(opts, message) do
    if pid = opts[:test_pid], do: send(pid, message)
  end
end
