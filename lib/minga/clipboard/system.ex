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
  """

  @behaviour Minga.Clipboard.Behaviour

  @impl true
  @spec read() :: String.t() | nil
  def read do
    case clipboard_tool() do
      :pbpaste -> run_read("pbpaste", [])
      :xclip -> run_read("xclip", ~w[-selection clipboard -o])
      :wl_paste -> run_read("wl-paste", ~w[--no-newline])
      :xsel -> run_read("xsel", ~w[--clipboard --output])
      :none -> nil
    end
  end

  @impl true
  @spec write(String.t()) :: :ok | :unavailable | {:error, term()}
  def write(text) when is_binary(text) do
    case clipboard_tool() do
      :pbpaste -> run_write("pbcopy", [], text)
      :xclip -> run_write("xclip", ~w[-selection clipboard], text)
      :wl_paste -> run_write("wl-copy", [], text)
      :xsel -> run_write("xsel", ~w[--clipboard --input], text)
      :none -> :unavailable
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec clipboard_tool() :: :pbpaste | :xclip | :wl_paste | :xsel | :none
  defp clipboard_tool do
    cond do
      tool_available?("pbpaste") -> :pbpaste
      tool_available?("wl-paste") -> :wl_paste
      tool_available?("xclip") -> :xclip
      tool_available?("xsel") -> :xsel
      true -> :none
    end
  end

  @spec tool_available?(String.t()) :: boolean()
  defp tool_available?(tool) do
    not is_nil(System.find_executable(tool))
  end

  @spec run_read(String.t(), [String.t()]) :: String.t() | nil
  defp run_read(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: false) do
      {output, 0} -> output
      _ -> nil
    end
  rescue
    ErlangError -> nil
  end

  @spec run_write(String.t(), [String.t()], String.t()) :: :ok | :unavailable | {:error, term()}
  defp run_write(cmd, args, text) do
    case System.find_executable(cmd) do
      nil ->
        :unavailable

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :use_stdio,
            args: args
          ])

        Port.command(port, text)
        send(port, {self(), :close})
        await_port_exit(port)
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, Exception.message(e)}
  end

  @spec await_port_exit(port()) :: :ok | {:error, term()}
  defp await_port_exit(port) do
    receive do
      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, code}} ->
        {:error, "exit #{code}"}

      {^port, :closed} ->
        receive do
          {^port, {:exit_status, 0}} -> :ok
          {^port, {:exit_status, code}} -> {:error, "exit #{code}"}
        after
          500 -> :ok
        end
    after
      5_000 -> {:error, :timeout}
    end
  end
end
