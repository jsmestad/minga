defmodule Minga.Editor.Commands.Operators do
  @moduledoc """
  Operator commands: delete/change/yank with motions, text objects, and
  line-wise variants (dd/yy/cc/S).
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Helpers
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode

  @type state :: EditorState.t()

  @command_specs [
    {:delete_line, "Delete current line", true},
    {:change_line, "Change current line", true},
    {:yank_line, "Yank current line", true}
  ]

  @spec execute(state(), Mode.command()) :: state()

  # ── Operator + motion ─────────────────────────────────────────────────────

  def execute(%{buffers: %{active: buf}} = state, {:delete_motion, motion}) do
    if read_only?(buf),
      do: read_only_msg(state),
      else: Helpers.apply_operator_motion(buf, state, motion, :delete)
  end

  def execute(%{buffers: %{active: buf}} = state, {:change_motion, motion}) do
    if read_only?(buf),
      do: read_only_msg(state),
      else: Helpers.apply_operator_motion(buf, state, motion, :delete)
  end

  def execute(%{buffers: %{active: buf}} = state, {:yank_motion, motion}) do
    Helpers.apply_operator_motion(buf, state, motion, :yank)
  end

  # ── Line-wise operators (dd / yy / cc / S) ────────────────────────────────

  def execute(%{buffers: %{active: buf}} = state, :delete_line) do
    if read_only?(buf) do
      read_only_msg(state)
    else
      {line, _col} = BufferServer.cursor(buf)
      yanked = BufferServer.get_lines_content(buf, line, line)
      BufferServer.delete_lines(buf, line, line)
      Helpers.put_register(state, yanked <> "\n", :delete, :linewise)
    end
  end

  def execute(%{buffers: %{active: buf}} = state, :change_line) do
    if read_only?(buf) do
      read_only_msg(state)
    else
      {line, _col} = BufferServer.cursor(buf)
      {:ok, yanked} = BufferServer.clear_line(buf, line)
      Helpers.put_register(state, yanked <> "\n", :delete, :linewise)
    end
  end

  def execute(%{buffers: %{active: buf}} = state, :yank_line) do
    {line, _col} = BufferServer.cursor(buf)
    yanked = BufferServer.get_lines_content(buf, line, line)
    Helpers.put_register(state, yanked <> "\n", :yank, :linewise)
  end

  # ── Text object operators ─────────────────────────────────────────────────

  def execute(%{buffers: %{active: buf}} = state, {:delete_text_object, modifier, spec})
      when is_pid(buf) do
    if read_only?(buf),
      do: read_only_msg(state),
      else: Helpers.apply_text_object(state, modifier, spec, :delete)
  end

  def execute(%{buffers: %{active: buf}} = state, {:change_text_object, modifier, spec})
      when is_pid(buf) do
    if read_only?(buf),
      do: read_only_msg(state),
      else: Helpers.apply_text_object(state, modifier, spec, :delete)
  end

  def execute(%{buffers: %{active: buf}} = state, {:yank_text_object, modifier, spec})
      when is_pid(buf) do
    Helpers.apply_text_object(state, modifier, spec, :yank)
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @spec read_only?(pid()) :: boolean()
  defp read_only?(buf), do: BufferServer.read_only?(buf)

  @spec read_only_msg(state()) :: state()
  defp read_only_msg(state), do: %{state | status_msg: "Buffer is read-only"}

  @impl Minga.Command.Provider
  def __commands__ do
    Enum.map(@command_specs, fn {name, desc, requires_buffer} ->
      %Minga.Command{
        name: name,
        description: desc,
        requires_buffer: requires_buffer,
        execute: fn state -> execute(state, name) end
      }
    end)
  end
end
