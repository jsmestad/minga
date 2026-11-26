defmodule MingaAgent.Notifier.OSAdapter.MacOS do
  @moduledoc "Sends a macOS desktop notification with `osascript`."

  @behaviour MingaAgent.Notifier.OSAdapter

  @impl true
  @spec send_notification(String.t(), String.t()) :: :ok
  def send_notification(title, message) do
    spawn(fn -> run(title, message) end)
    :ok
  end

  @spec run(String.t(), String.t()) :: :ok
  defp run(title, message) do
    System.cmd("osascript", [
      "-e",
      ~s(display notification "#{escape(message)}" with title "#{escape(title)}")
    ])

    :ok
  rescue
    e -> Minga.Log.debug(:agent, "OS notification failed: #{Exception.message(e)}")
  end

  @spec escape(String.t()) :: String.t()
  defp escape(text) do
    text |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"") |> String.slice(0, 200)
  end
end
