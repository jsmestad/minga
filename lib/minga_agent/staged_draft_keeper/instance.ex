defmodule MingaAgent.StagedDraftKeeper.Instance do
  @moduledoc """
  Identifies this Minga instance in staged draft owner records, and checks whether another instance is still running.

  An instance is its OS process id plus that process's start time. A process id alone is not enough: the OS reuses it, so a record of an instance that exited could name an unrelated live process. The start time must read the same from every instance for as long as the process runs, whatever their time zones and however the wall clock moves:

    * On Linux it is the boot id plus field 22 of `/proc/<pid>/stat` (`starttime`, clock ticks since boot), which a clock step does not move.
    * Elsewhere (macOS) it is `ps -o lstart=` run with `TZ=UTC0` and `LC_ALL=C`, so the time zone of either instance, or a change of the system time zone, does not change it.

  If neither source works, this instance is identified by its process id and a random token, and every other instance counts as gone, which is the behavior without owner records.
  """

  alias Minga.Session.StagedDrafts

  @typedoc "Variables added to the environment `ps` inherits, as another instance's environment would differ (for tests)."
  @type env :: [{String.t(), String.t()}]

  @doc "Returns this instance's identity."
  @spec current(env()) :: StagedDrafts.owner()
  def current(env \\ []) do
    os_pid = System.pid() |> String.to_integer()

    case start_time(os_pid, env) do
      {:ok, started} ->
        %{os_pid: os_pid, started: started}

      :error ->
        %{os_pid: os_pid, started: "unknown-" <> Base.encode16(:crypto.strong_rand_bytes(8))}
    end
  end

  @doc "Returns whether the process an owner record names is still the same running process."
  @spec alive?(StagedDrafts.owner(), env()) :: boolean()
  def alive?(%{os_pid: os_pid, started: started}, env \\ []),
    do: start_time(os_pid, env) == {:ok, started}

  @spec start_time(pos_integer(), env()) :: {:ok, String.t()} | :error
  defp start_time(os_pid, env) do
    case File.read("/proc/sys/kernel/random/boot_id") do
      {:ok, boot_id} -> proc_start_time(String.trim(boot_id), os_pid)
      {:error, _no_procfs} -> ps_start_time(os_pid, env)
    end
  end

  # The process name in field 2 may hold spaces and parentheses; the fields
  # after its closing parenthesis start at field 3, so `starttime` (22) is
  # the 20th of them.
  @spec proc_start_time(String.t(), pos_integer()) :: {:ok, String.t()} | :error
  defp proc_start_time(boot_id, os_pid) do
    with {:ok, stat} <- File.read("/proc/#{os_pid}/stat"),
         # Greedy: everything after the last closing parenthesis.
         [fields] <- Regex.run(~r/\A.*\) (.*)\z/s, stat, capture: :all_but_first),
         ticks when is_binary(ticks) <- fields |> String.split(" ", trim: true) |> Enum.at(19) do
      {:ok, "linux #{boot_id} #{ticks}"}
    else
      _gone -> :error
    end
  end

  @spec ps_start_time(pos_integer(), env()) :: {:ok, String.t()} | :error
  defp ps_start_time(os_pid, env) do
    # The fixed time zone and locale override whatever the instance runs with.
    env = env |> Map.new() |> Map.merge(%{"LC_ALL" => "C", "TZ" => "UTC0"}) |> Map.to_list()

    case System.cmd("ps", ["-o", "lstart=", "-p", Integer.to_string(os_pid)],
           env: env,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case String.trim(output) do
          "" -> :error
          started -> {:ok, started}
        end

      {_output, _status} ->
        :error
    end
  rescue
    # `ps` is not installed.
    ErlangError -> :error
  end
end
