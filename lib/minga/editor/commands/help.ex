defmodule Minga.Editor.Commands.Help do
  @moduledoc """
  Help commands: describe-key result display and `*Help*` buffer management.

  The `*Help*` buffer is created lazily on first use, reused across
  invocations, and is always read-only.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer
  alias Minga.Editor.Commands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode

  @type state :: EditorState.t()

  @spec execute(state(), Mode.command()) :: state()
  def execute(state, {:describe_key_result, key_str, command, description}) do
    content = format_describe_key(key_str, command, description)
    show_in_help_buffer(state, content)
  end

  def execute(state, {:describe_key_not_found, key_str}) do
    content = "Key not bound: #{key_str}\n"
    show_in_help_buffer(state, content)
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  @spec format_describe_key(String.t(), atom(), String.t()) :: String.t()
  defp format_describe_key(key_str, command, description) do
    lines = [
      "Key:         #{key_str}",
      "Command:     #{command}",
      "Description: #{description}",
      ""
    ]

    Enum.join(lines, "\n")
  end

  @spec show_in_help_buffer(state(), String.t()) :: state()
  defp show_in_help_buffer(state, content) do
    {state, help_buf} = ensure_help_buffer(state)
    replace_help_content(help_buf, content)

    # Switch to help buffer
    idx = Enum.find_index(state.workspace.buffers.list, &(&1 == help_buf))

    state =
      if idx do
        put_in(state.workspace.buffers.active_index, idx)
        |> then(fn s -> put_in(s.workspace.buffers.active, help_buf) end)
      else
        Commands.add_buffer(state, help_buf)
      end

    EditorState.clear_status(state)
  end

  @spec ensure_help_buffer(state()) :: {state(), pid()}
  defp ensure_help_buffer(%{workspace: %{buffers: %{help: buf}}} = state)
       when is_pid(buf) and buf != nil do
    Buffer.buffer_name(buf)
    {state, buf}
  catch
    :exit, _ -> start_help_buffer(state)
  end

  defp ensure_help_buffer(state) do
    start_help_buffer(state)
  end

  @spec start_help_buffer(state()) :: {state(), pid()}
  defp start_help_buffer(state) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        Minga.Buffer.Supervisor,
        {Minga.Buffer,
         content: "", buffer_name: "*Help*", read_only: true, unlisted: true, persistent: true}
      )

    {put_in(state.workspace.buffers.help, pid), pid}
  end

  @spec replace_help_content(pid(), String.t()) :: :ok
  defp replace_help_content(buf, content) do
    :sys.replace_state(buf, fn s ->
      %{s | document: Document.new(content)}
    end)

    Buffer.move_to(buf, {0, 0})
  end
end
