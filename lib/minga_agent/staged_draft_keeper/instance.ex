defmodule MingaAgent.StagedDraftKeeper.Instance do
  @moduledoc """
  Identifies this Minga instance in staged draft owner records, and checks whether another instance is still running.

  An instance is its OS process id plus that process's start time as `ps` reports it. A process id alone is not enough: the OS reuses it, so a record of an instance that exited could name an unrelated live process. Both values come from `ps` for this process and for the recorded one, so they compare exactly.

  If `ps` cannot run, this instance is identified by its process id and a random token, and every other instance counts as gone, which is the behavior without owner records.
  """

  alias Minga.Session.StagedDrafts

  @doc "Returns this instance's identity."
  @spec current() :: StagedDrafts.owner()
  def current do
    os_pid = System.pid() |> String.to_integer()

    case start_time(os_pid) do
      {:ok, started} ->
        %{os_pid: os_pid, started: started}

      :error ->
        %{os_pid: os_pid, started: "unknown-" <> Base.encode16(:crypto.strong_rand_bytes(8))}
    end
  end

  @doc "Returns whether the process an owner record names is still the same running process."
  @spec alive?(StagedDrafts.owner()) :: boolean()
  def alive?(%{os_pid: os_pid, started: started}), do: start_time(os_pid) == {:ok, started}

  @spec start_time(pos_integer()) :: {:ok, String.t()} | :error
  defp start_time(os_pid) do
    case System.cmd("ps", ["-o", "lstart=", "-p", Integer.to_string(os_pid)],
           env: [{"LC_ALL", "C"}],
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
