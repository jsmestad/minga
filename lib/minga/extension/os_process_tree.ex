defmodule Minga.Extension.OSProcessTree do
  @moduledoc """
  Stops an OS process together with every process it started.

  A disposable extension build runs in a child `erl`, and that BEAM starts build tools through its own `erl_child_setup`. The runtime puts each port program in a new session, so the tools do not share a process group with the `erl` that started them. Signalling the `erl` process group would therefore miss them. This module follows parent links and process-group membership from one `ps` snapshot instead.

  Each pass stops (`SIGSTOP`) the processes it has not stopped yet, so they cannot exit or start new children while the tree is collected. Passes repeat until a snapshot finds no new process. Then every collected process receives `SIGKILL`. A process that a build detached before the stop (its parent exited and it left the build's process groups) is not reachable from the tree and is not stopped.

  When `ps` is not available or its output cannot be read, only the root process receives `SIGKILL`. When `kill` is not available, nothing is signalled.
  """

  @max_passes 8

  @typedoc "One `ps` row: process id, parent process id, process-group id."
  @type row :: {pid :: pos_integer(), ppid :: non_neg_integer(), pgid :: non_neg_integer()}

  @doc "Stops `root` and every process reachable from it, then kills them all."
  @spec kill(pos_integer()) :: :ok
  def kill(root) when is_integer(root) and root > 1 do
    case {System.find_executable("kill"), System.find_executable("ps")} do
      {nil, _ps} ->
        :ok

      {kill, nil} ->
        signal(kill, "-KILL", [root])

      {kill, ps} ->
        signal(kill, "-STOP", [root])
        stopped = stop_tree(ps, kill, root, MapSet.new([root]), @max_passes)
        signal(kill, "-KILL", MapSet.to_list(stopped))
    end
  end

  def kill(_root), do: :ok

  @doc """
  Returns every process reachable from `root` in `rows`, excluding `root`.

  A process is reachable when its parent is reachable, or when it belongs to a process group whose leader is reachable. The second rule finds processes whose parent shell already exited inside a build-owned process group. `exclude` lists processes that must never be returned, such as the calling BEAM.
  """
  @spec descendants([row()], pos_integer(), [pos_integer()]) :: [pos_integer()]
  def descendants(rows, root, exclude \\ []) do
    excluded = MapSet.new([1 | exclude])

    if MapSet.member?(excluded, root) do
      []
    else
      by_parent = Enum.group_by(rows, &elem(&1, 1), &elem(&1, 0))
      by_group = Enum.group_by(rows, &elem(&1, 2), &elem(&1, 0))

      [root]
      |> walk(by_parent, by_group, MapSet.put(excluded, root))
      |> MapSet.difference(excluded)
      |> MapSet.delete(root)
      |> MapSet.to_list()
    end
  end

  @doc "Parses `ps -A -o pid= -o ppid= -o pgid=` output, skipping malformed lines."
  @spec parse_ps(String.t()) :: [row()]
  def parse_ps(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_row/1)
  end

  @spec parse_row(String.t()) :: [row()]
  defp parse_row(line) do
    with [pid, ppid, pgid] <- String.split(line),
         {pid, ""} when pid > 0 <- Integer.parse(pid),
         {ppid, ""} when ppid >= 0 <- Integer.parse(ppid),
         {pgid, ""} when pgid >= 0 <- Integer.parse(pgid) do
      [{pid, ppid, pgid}]
    else
      _malformed -> []
    end
  end

  @spec walk([pos_integer()], map(), map(), MapSet.t(pos_integer())) :: MapSet.t(pos_integer())
  defp walk([], _by_parent, _by_group, seen), do: seen

  defp walk([pid | rest], by_parent, by_group, seen) do
    reached =
      Map.get(by_parent, pid, []) ++ Map.get(by_group, pid, [])

    new = Enum.reject(reached, &MapSet.member?(seen, &1))
    walk(new ++ rest, by_parent, by_group, Enum.into(new, seen))
  end

  @spec stop_tree(
          String.t(),
          String.t(),
          pos_integer(),
          MapSet.t(pos_integer()),
          non_neg_integer()
        ) ::
          MapSet.t(pos_integer())
  defp stop_tree(_ps, _kill, _root, stopped, 0), do: stopped

  defp stop_tree(ps, kill, root, stopped, passes) do
    case snapshot(ps) do
      {:ok, rows} ->
        new =
          rows
          |> descendants(root, [System.pid() |> String.to_integer()])
          |> Enum.reject(&MapSet.member?(stopped, &1))

        stop_new(ps, kill, root, stopped, new, passes)

      :error ->
        stopped
    end
  end

  @spec stop_new(
          String.t(),
          String.t(),
          pos_integer(),
          MapSet.t(pos_integer()),
          [pos_integer()],
          non_neg_integer()
        ) :: MapSet.t(pos_integer())
  defp stop_new(_ps, _kill, _root, stopped, [], _passes), do: stopped

  defp stop_new(ps, kill, root, stopped, new, passes) do
    signal(kill, "-STOP", new)
    stop_tree(ps, kill, root, Enum.into(new, stopped), passes - 1)
  end

  @spec snapshot(String.t()) :: {:ok, [row()]} | :error
  defp snapshot(ps) do
    case System.cmd(ps, ["-A", "-o", "pid=", "-o", "ppid=", "-o", "pgid="]) do
      {output, 0} -> {:ok, parse_ps(output)}
      {_output, _status} -> :error
    end
  rescue
    _error -> :error
  end

  @spec signal(String.t(), String.t(), [pos_integer()]) :: :ok
  defp signal(_kill, _signal, []), do: :ok

  defp signal(kill, signal, pids) do
    # `kill` signals every listed pid and reports failure when any already exited.
    _ = System.cmd(kill, [signal | Enum.map(pids, &Integer.to_string/1)], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end
end
