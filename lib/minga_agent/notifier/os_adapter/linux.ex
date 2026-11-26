defmodule MingaAgent.Notifier.OSAdapter.Linux do
  @moduledoc """
  Sends freedesktop desktop notifications with `notify-send` from libnotify.

  Notification servers such as mako (Omarchy), GNOME Shell and KDE Plasma show them. The `minga` icon and desktop entry come from the Linux packages. Without a graphical session (SSH, a TTY) or without `notify-send`, nothing is sent and the reason is logged at debug level.
  """

  @behaviour MingaAgent.Notifier.OSAdapter

  @typedoc "Environment variables, as returned by `System.get_env/0`."
  @type environment :: %{optional(String.t()) => String.t()}

  @typedoc "Finds an executable on `PATH`, as `System.find_executable/1` does."
  @type finder :: (String.t() -> String.t() | nil)

  @typedoc "The command to run, or why no notification can be shown."
  @type plan :: {:run, String.t(), [String.t()]} | {:skip, String.t()}

  @impl true
  @spec send_notification(String.t(), String.t()) :: :ok
  def send_notification(title, message) do
    spawn(fn -> deliver(title, message) end)
    :ok
  end

  @spec deliver(String.t(), String.t()) :: :ok
  defp deliver(title, message) do
    case command(title, message, System.get_env(), &System.find_executable/1) do
      {:run, executable, args} -> run(executable, args)
      {:skip, reason} -> Minga.Log.debug(:agent, "Desktop notification skipped: #{reason}")
    end
  end

  @doc """
  Plans the `notify-send` invocation for a notification.

  Arguments are passed directly, never through a shell. A notification needs a Wayland or X11 session and `notify-send` on `PATH`.
  """
  @spec command(String.t(), String.t(), environment(), finder()) :: plan()
  def command(title, message, environment, find_executable) do
    cond do
      not graphical_session?(environment) ->
        {:skip, "no graphical session (WAYLAND_DISPLAY and DISPLAY are unset)"}

      executable = find_executable.("notify-send") ->
        {:run, executable,
         [
           "--app-name=Minga",
           "--icon=minga",
           "--hint=string:desktop-entry:minga",
           title,
           message
         ]}

      true ->
        {:skip, "notify-send is not installed (install libnotify)"}
    end
  end

  @spec graphical_session?(environment()) :: boolean()
  defp graphical_session?(environment) do
    Enum.any?(["WAYLAND_DISPLAY", "DISPLAY"], &(Map.get(environment, &1, "") != ""))
  end

  @spec run(String.t(), [String.t()]) :: :ok
  defp run(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        Minga.Log.debug(:agent, "notify-send exited #{status}: #{String.trim(output)}")
    end
  rescue
    error ->
      Minga.Log.debug(:agent, "Desktop notification failed: #{Exception.message(error)}")
  end
end
