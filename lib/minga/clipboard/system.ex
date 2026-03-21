defmodule Minga.Clipboard.System do
  @moduledoc """
  System clipboard backend using platform-native tools.

  Reads from and writes to the system clipboard using the best available
  tool for the current platform:

  - **macOS**: `pbpaste` / `pbcopy`
  - **Linux (Wayland)**: `wl-paste` / `wl-copy`
  - **Linux (X11)**: `xclip -selection clipboard`
  - **Linux (X11 alt)**: `xsel --clipboard`

  All functions degrade gracefully: `read/0` returns `nil` and `write/1`
  returns `:unavailable` when no clipboard tool is found.

  ## Executable caching

  The clipboard tool and its path are detected once on first use and cached
  in `:persistent_term`. The tool doesn't change during a session, so
  repeating `System.find_executable/1` on every read/write is wasted work.
  """

  @behaviour Minga.Clipboard.Behaviour

  # Cached tool info stores the resolved paths for both the read and write
  # executables. The clipboard tool doesn't change during a session, so we
  # detect once and cache in :persistent_term to avoid repeated PATH lookups.
  @typep tool_info ::
           %{read: {String.t(), [String.t()]}, write: {String.t(), [String.t()]}}
           | :none

  @impl true
  @spec read() :: String.t() | nil
  def read do
    case cached_tool_info() do
      %{read: {path, args}} -> run_read(path, args)
      :none -> nil
    end
  end

  @impl true
  @spec write(String.t()) :: :ok | :unavailable | {:error, term()}
  def write(text) when is_binary(text) do
    case cached_tool_info() do
      %{write: {path, args}} -> run_write(path, args, text)
      :none -> :unavailable
    end
  end

  # ── Tool detection and caching ─────────────────────────────────────────────

  @persistent_term_key {__MODULE__, :tool_info}

  @spec cached_tool_info() :: tool_info()
  defp cached_tool_info do
    case :persistent_term.get(@persistent_term_key, nil) do
      nil ->
        info = detect_tool()
        :persistent_term.put(@persistent_term_key, info)
        info

      info ->
        info
    end
  end

  @doc false
  @spec reset_cache() :: :ok
  def reset_cache do
    :persistent_term.erase(@persistent_term_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec detect_tool() :: tool_info()
  defp detect_tool do
    find_platform("pbcopy", "pbpaste", [], []) ||
      find_platform("wl-copy", "wl-paste", [], ~w[--no-newline]) ||
      find_platform("xclip", "xclip", ~w[-selection clipboard], ~w[-selection clipboard -o]) ||
      find_platform("xsel", "xsel", ~w[--clipboard --input], ~w[--clipboard --output]) ||
      :none
  end

  @spec find_platform(String.t(), String.t(), [String.t()], [String.t()]) :: tool_info() | nil
  defp find_platform(write_cmd, read_cmd, write_args, read_args) do
    with write_path when write_path != nil <- System.find_executable(write_cmd),
         read_path when read_path != nil <- System.find_executable(read_cmd) do
      %{write: {write_path, write_args}, read: {read_path, read_args}}
    else
      _ -> nil
    end
  end

  # ── Read/Write ─────────────────────────────────────────────────────────────

  @spec run_read(String.t(), [String.t()]) :: String.t() | nil
  defp run_read(executable, args) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: args
      ])

    collect_port_output(port, [])
  rescue
    ErlangError -> nil
    ArgumentError -> nil
  end

  @spec collect_port_output(port(), [binary()]) :: String.t() | nil
  defp collect_port_output(port, chunks) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, [data | chunks])

      {^port, {:exit_status, 0}} ->
        chunks |> Enum.reverse() |> IO.iodata_to_binary()

      {^port, {:exit_status, _code}} ->
        nil
    after
      5_000 ->
        Port.close(port)
        nil
    end
  end

  @spec run_write(String.t(), [String.t()], String.t()) :: :ok | {:error, term()}
  defp run_write(executable, args, text) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: args
      ])

    Port.command(port, text)
    # Close the port's stdin so the clipboard tool sees EOF and processes
    # the data. We then wait only for the {:closed} or {:exit_status}
    # message, whichever arrives first. The old code waited 500ms for an
    # exit_status that never arrived after :closed.
    send(port, {self(), :close})
    await_port_close(port)
  rescue
    e in [ErlangError, ArgumentError] -> {:error, Exception.message(e)}
  end

  @spec await_port_close(port()) :: :ok | {:error, term()}
  defp await_port_close(port) do
    result =
      receive do
        {^port, :closed} -> :ok
        {^port, {:exit_status, 0}} -> :ok
        {^port, {:exit_status, code}} -> {:error, "exit #{code}"}
      after
        5_000 -> {:error, :timeout}
      end

    # Best-effort drain: catches the trailing :exit_status (if :closed arrived
    # first) or trailing :closed (if :exit_status arrived first). The Task
    # calling write/1 is short-lived, so any leaked message is cleaned up on
    # task exit. Long-lived callers benefit from the drain but are not harmed
    # if the trailing message hasn't been delivered yet.
    receive do
      {^port, _} -> :ok
    after
      0 -> :ok
    end

    result
  end
end
