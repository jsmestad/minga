defmodule Minga.Session.Instance do
  @moduledoc """
  Identifies one run of Minga in the files it leaves for a later run, and checks whether another run is still alive.

  Staged draft owner records and swap files both have to answer "is the Minga that wrote this still running?". This module is the one place that decides it.

  An instance is its OS process id plus that process's start time. A process id alone is not enough: the OS reuses it, so a record of an instance that exited could name an unrelated live process, and after a reboot a new Minga often gets the id an old one had. The start time comes from the OS in a form that does not depend on settings of either process:

    * On Linux it is the boot id plus field 22 of `/proc/<pid>/stat` (`starttime`, clock ticks since boot), which a clock step does not move.
    * Elsewhere (macOS) it is `ps -o lstart=` run with `TZ=UTC0` and `LC_ALL=C`, so the time zone of either instance, or a change of the system time zone, does not change it.

  Both sides read the same value from the OS, so the comparison is exact: no tolerance, and nothing that a launcher script running before the VM, or a stepped clock, could move. A zombie process has exited and only waits for its parent, so it counts as gone.

  If neither source works, this instance is identified by its process id and a random token, and every other instance counts as gone, which is the behavior without owner records.
  """

  alias Minga.Session.StagedDrafts

  @typedoc "One run of Minga: its OS process id and the start time the OS reports for that process."
  @type t :: StagedDrafts.owner()

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

  @doc """
  Returns the start time the OS reports for a process id, or `:error` when no such process runs (a zombie included).

  The value is opaque: compare it for equality with the `started` of an owner record.
  """
  @spec start_time(pos_integer(), env()) :: {:ok, String.t()} | :error
  def start_time(os_pid, env \\ []) when is_integer(os_pid) and os_pid > 0 do
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
         [state | _rest] = fields <- String.split(fields, " ", trim: true),
         :running <- process_state(state),
         ticks when is_binary(ticks) <- Enum.at(fields, 19) do
      {:ok, "linux #{boot_id} #{ticks}"}
    else
      _gone -> :error
    end
  end

  # The state letters of `/proc/<pid>/stat` (field 3) and of `ps -o stat=`. `Z` is a zombie.
  @spec process_state(String.t()) :: :running | :zombie
  defp process_state("Z" <> _flags), do: :zombie
  defp process_state(_state), do: :running

  @spec ps_start_time(pos_integer(), env()) :: {:ok, String.t()} | :error
  defp ps_start_time(os_pid, env) do
    # The fixed time zone and locale override whatever the instance runs with.
    env = env |> Map.new() |> Map.merge(%{"LC_ALL" => "C", "TZ" => "UTC0"}) |> Map.to_list()

    case System.cmd("ps", ["-o", "stat=", "-o", "lstart=", "-p", Integer.to_string(os_pid)],
           env: env,
           stderr_to_stdout: true
         ) do
      {output, 0} -> parse_ps(output)
      {_output, _status} -> :error
    end
  rescue
    # `ps` is not installed.
    ErlangError -> :error
  end

  @doc """
  Reads one `ps -o stat= -o lstart=` line: the state letters, then the start time.

  An empty line means no such process. A state that starts with `Z` is a zombie, which has exited.
  """
  @spec parse_ps(String.t()) :: {:ok, String.t()} | :error
  def parse_ps(output) when is_binary(output) do
    with [state, started] <- String.split(String.trim(output), ~r/\s+/, parts: 2),
         :running <- process_state(state) do
      {:ok, String.trim(started)}
    else
      _gone_or_zombie -> :error
    end
  end
end
