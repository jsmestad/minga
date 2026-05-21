defmodule MingaEditor.Commands.InlineEdit do
  @moduledoc """
  Inline edit commands.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer
  alias Minga.Command
  alias Minga.Mode.VisualState
  alias Minga.Project.FileRef
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.InlineEdit

  @type state :: EditorState.t()

  @impl true
  @spec __commands__() :: [Command.t()]
  def __commands__ do
    [
      %Command{
        name: :inline_edit,
        description: "Rewrite the visual selection inline",
        requires_buffer: true,
        execute: &open/1
      }
    ]
  end

  @doc "Opens an inline edit for the active visual selection."
  @spec open(state()) :: state()
  def open(
        %{
          workspace: %{
            buffers: %{active: buffer_pid},
            editing: %{mode: mode, mode_state: %VisualState{}}
          }
        } = state
      )
      when is_pid(buffer_pid) and mode in [:visual, :visual_line] do
    {first, last} = selection_range(state)
    {:ok, file_ref, label} = file_ref_for_active_buffer(state, buffer_pid)
    original = Buffer.content_on_lines(buffer_pid, first, last)
    edit = InlineEdit.new(buffer_pid, file_ref, label, {first, last}, original)
    edits = state |> EditorState.inline_edits() |> InlineEdit.put(edit)

    state
    |> EditorState.set_inline_edits(edits)
    |> EditorState.set_status("Inline edit: type rewrite instruction")
  end

  def open(state), do: EditorState.set_status(state, "Inline edit requires a visual selection")

  @doc "Accepts a proposed inline edit into the buffer."
  @spec accept(state(), InlineEdit.t()) :: state()
  def accept(state, %InlineEdit{status: status}) when status != :proposed do
    EditorState.set_status(state, "Wait for an inline edit proposal first")
  end

  def accept(state, %InlineEdit{} = edit) do
    if Buffer.read_only?(edit.buffer_pid) do
      EditorState.set_status(state, "Inline edit failed: :read_only")
    else
      apply_accepted_edit(state, edit)
    end
  end

  @spec apply_accepted_edit(state(), InlineEdit.t()) :: state()
  defp apply_accepted_edit(state, %InlineEdit{} = edit) do
    {first, last} = edit.selection_range
    last_col = last_line_length(edit.buffer_pid, last)
    replacement = replacement_text(edit.buffer_pid, last, edit.proposed_rewrite)
    :ok = Buffer.apply_edit(edit.buffer_pid, first, 0, last, last_col, replacement)
    accept_success(state, edit)
  end

  @spec accept_success(state(), InlineEdit.t()) :: state()
  defp accept_success(state, %InlineEdit{} = edit) do
    {edits, _session_pid} =
      state |> EditorState.inline_edits() |> InlineEdit.dismiss(edit.buffer_pid)

    state
    |> EditorState.set_inline_edits(edits)
    |> EditorState.transition_mode(:normal)
    |> EditorState.set_status("Inline edit accepted")
  end

  @doc "Dismisses an inline edit without mutating the buffer."
  @spec reject(state(), InlineEdit.t()) :: state()
  def reject(state, %InlineEdit{} = edit) do
    MingaAgent.EphemeralSession.stop(edit.session_pid)

    {edits, _session_pid} =
      state |> EditorState.inline_edits() |> InlineEdit.dismiss(edit.buffer_pid)

    EditorState.set_inline_edits(state, edits)
  end

  @spec selection_range(state()) :: {non_neg_integer(), non_neg_integer()}
  defp selection_range(%{
         workspace: %{buffers: %{active: buffer_pid}, editing: %{mode_state: %VisualState{} = ms}}
       }) do
    {cursor_line, _col} = Buffer.cursor(buffer_pid)
    {anchor_line, _col} = ms.visual_anchor
    {min(cursor_line, anchor_line), max(cursor_line, anchor_line)}
  end

  @spec file_ref_for_active_buffer(state(), pid()) :: {:ok, FileRef.t(), String.t()}
  defp file_ref_for_active_buffer(state, buffer_pid) do
    case Buffer.file_path(buffer_pid) do
      path when is_binary(path) ->
        root = project_root(state)

        case FileRef.from_path(root, path) do
          {:ok, file_ref} ->
            {:ok, file_ref, file_ref.display_name}

          {:error, :outside_project} ->
            {:ok, FileRef.from_buffer(buffer_pid), Path.basename(path)}
        end

      _ ->
        file_ref = FileRef.from_buffer(buffer_pid)
        {:ok, file_ref, file_ref.display_name}
    end
  end

  @spec project_root(state()) :: String.t()
  defp project_root(%{workspace: %{file_tree: %{project_root: root}}}) when is_binary(root),
    do: root

  defp project_root(%{workspace: %{file_tree: %{original_root: root}}}) when is_binary(root),
    do: root

  defp project_root(_state), do: File.cwd!()

  @spec replacement_text(pid(), non_neg_integer(), String.t()) :: String.t()
  defp replacement_text(_buffer_pid, _last, ""), do: ""

  defp replacement_text(buffer_pid, last, proposed) do
    if last < Buffer.line_count(buffer_pid) - 1 and not String.ends_with?(proposed, "\n") do
      proposed <> "\n"
    else
      proposed
    end
  end

  @spec last_line_length(pid(), non_neg_integer()) :: non_neg_integer()
  defp last_line_length(buffer_pid, line) do
    buffer_pid
    |> Buffer.lines(line, 1)
    |> List.first()
    |> case do
      text when is_binary(text) -> byte_size(text)
      _ -> 0
    end
  end
end
