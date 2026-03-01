defmodule Minga.Clipboard do
  @moduledoc """
  Platform clipboard integration.

  Reads from and writes to the system clipboard using the best available
  tool for the current platform:

  - **macOS**: `pbpaste` / `pbcopy`
  - **Linux (Wayland)**: `wl-paste` / `wl-copy`
  - **Linux (X11)**: `xclip -selection clipboard`
  - **Linux (X11 alt)**: `xsel --clipboard`

  All functions degrade gracefully: `read/0` returns `nil` and `write/1`
  returns `:unavailable` when no clipboard tool is found.
  """

  @typedoc "Result of a clipboard read."
  @type read_result :: String.t() | nil

  @typedoc "Result of a clipboard write."
  @type write_result :: :ok | :unavailable | {:error, term()}

  @doc """
  Reads the current system clipboard contents.

  Returns `nil` if no clipboard tool is available or the read fails.
  """
  @spec read() :: read_result()
  def read do
    case clipboard_tool() do
      :pbpaste -> run_read("pbpaste", [])
      :xclip -> run_read("xclip", ~w[-selection clipboard -o])
      :wl_paste -> run_read("wl-paste", ~w[--no-newline])
      :xsel -> run_read("xsel", ~w[--clipboard --output])
      :none -> nil
    end
  end

  @doc """
  Writes `text` to the system clipboard.

  Returns `:ok` on success, `:unavailable` if no clipboard tool is found,
  or `{:error, reason}` on failure.
  """
  @spec write(String.t()) :: write_result()
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
    _ -> nil
  end

  # Write text to a command's stdin using a Port so we can pipe data without
  # relying on a shell or a non-existent `input:` option in System.cmd.
  @spec run_write(String.t(), [String.t()], String.t()) :: write_result()
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
        # Closing the port sends EOF to the child's stdin.
        send(port, {self(), :close})
        await_port_exit(port)
    end
  rescue
    error -> {:error, inspect(error)}
  end

  @spec await_port_exit(port()) :: write_result()
  defp await_port_exit(port) do
    receive do
      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, code}} ->
        {:error, "exit #{code}"}

      {^port, :closed} ->
        # Port acknowledged close; wait briefly for the exit status.
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
