defmodule Minga.Frontend.Adapter.GUI.FileTreeEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.FileTree
  alias Minga.RenderModel.UI.FileTree.Row

  @op_gui_file_tree Opcodes.gui_file_tree()
  @op_gui_file_tree_selection Opcodes.gui_file_tree_selection()

  @type ready_fingerprint :: {:ready, non_neg_integer(), non_neg_integer()}
  @type fingerprint ::
          ready_fingerprint()
          | {:file_tree_state, String.t(), non_neg_integer(), term()}
          | {:no_tree, String.t()}

  @spec encode(FileTree.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%FileTree{status: :ready} = model, %Caches{} = caches) do
    structural_fp = ready_structural_fingerprint(model)
    selection_fp = selection_fingerprint(model)
    fp = {:ready, structural_fp, selection_fp}

    case caches.last_file_tree_fp do
      {:ready, ^structural_fp, ^selection_fp} ->
        {nil, caches}

      {:ready, ^structural_fp, _previous_selection_fp} ->
        {encode_selection_command(model), %{caches | last_file_tree_fp: fp}}

      _previous_fp ->
        {encode_command(model), %{caches | last_file_tree_fp: fp}}
    end
  end

  def encode(%FileTree{} = model, %Caches{} = caches) do
    fp = fingerprint(model)

    if fp != caches.last_file_tree_fp do
      {encode_command(model), %{caches | last_file_tree_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_command(FileTree.t()) :: binary()
  def encode_command(%FileTree{} = model) do
    root = model.root_path || ""
    error_reason = error_reason(model.status)

    payload =
      IO.iodata_to_binary([
        <<2::8, file_tree_flags(model.status, model.focused?)::8,
          encode_file_tree_status(model.status)::8>>,
        Wire.encode_string16(model.selected_id),
        Wire.encode_string16(root),
        <<model.tree_width::16, length(model.rows)::16>>,
        Wire.encode_string16(error_reason),
        Enum.map(model.rows, &encode_row(&1, root, model))
      ])

    <<@op_gui_file_tree, byte_size(payload)::32, payload::binary>>
  end

  @spec encode_selection_command(FileTree.t()) :: binary()
  defp encode_selection_command(%FileTree{} = model) do
    payload =
      IO.iodata_to_binary([
        <<file_tree_selection_flags(model.focused?)::8>>,
        Wire.encode_string16(model.selected_id)
      ])

    <<@op_gui_file_tree_selection, byte_size(payload)::16, payload::binary>>
  end

  @spec fingerprint(FileTree.t()) :: fingerprint()
  defp fingerprint(%FileTree{status: :hidden, root_path: root_path}) do
    {:no_tree, root_path || ""}
  end

  defp fingerprint(%FileTree{} = model) do
    {:file_tree_state, model.root_path || "", model.tree_width, model.status}
  end

  @spec ready_structural_fingerprint(FileTree.t()) :: non_neg_integer()
  defp ready_structural_fingerprint(%FileTree{} = model) do
    rows = Enum.map(model.rows, &structural_row/1)
    :erlang.phash2({model.root_path, model.tree_width, model.status, rows})
  end

  @spec selection_fingerprint(FileTree.t()) :: non_neg_integer()
  defp selection_fingerprint(%FileTree{} = model) do
    :erlang.phash2({model.selected_id, model.focused?})
  end

  @spec structural_row(Row.t()) :: Row.t()
  defp structural_row(%Row{} = row) do
    row
  end

  @spec encode_row(Row.t(), String.t(), FileTree.t()) :: iodata()
  defp encode_row(%Row{} = row, root, %FileTree{} = model) do
    editing_type = if row.editing, do: encode_editing_type(row.editing.type), else: 0xFF
    editing_text = if row.editing, do: row.editing.text, else: ""
    guides = Enum.map(row.guides, fn guide? -> if guide?, do: <<1>>, else: <<0>> end)
    {errors, warnings, info, hints} = clamp_diagnostics(row.diagnostics)

    [
      <<:erlang.phash2(row.id, 0xFFFFFFFF)::32, file_tree_row_flags(row, model)::16, row.depth::8,
        encode_git_status(row.git_status)::8, errors::16, warnings::16, info::16, hints::16,
        length(row.guides)::8>>,
      guides,
      Wire.encode_string16(row.id),
      Wire.encode_string16(row.path),
      Wire.encode_string16(Path.relative_to(row.path, root)),
      Wire.encode_string16(row.name),
      Wire.encode_string8(row.icon),
      <<editing_type::8>>,
      Wire.encode_string16(editing_text)
    ]
  end

  @spec clamp_diagnostics(Row.diagnostics()) :: Row.diagnostics()
  defp clamp_diagnostics({errors, warnings, info, hints}) do
    {Wire.clamp_u16(errors), Wire.clamp_u16(warnings), Wire.clamp_u16(info),
     Wire.clamp_u16(hints)}
  end

  @spec file_tree_selection_flags(boolean()) :: non_neg_integer()
  defp file_tree_selection_flags(focused?), do: Wire.maybe_flag(0, focused?, 0)

  @spec file_tree_flags(FileTree.status(), boolean()) :: non_neg_integer()
  defp file_tree_flags(status, focused?) do
    0
    |> Wire.maybe_flag(visible_status?(status), 0)
    |> Wire.maybe_flag(focused?, 1)
    |> Wire.maybe_flag(status == :empty, 4)
  end

  @spec visible_status?(FileTree.status()) :: boolean()
  defp visible_status?(:hidden), do: false
  defp visible_status?(_status), do: true

  @spec encode_file_tree_status(FileTree.status()) :: non_neg_integer()
  defp encode_file_tree_status(:hidden), do: 0
  defp encode_file_tree_status(:loading), do: 1
  defp encode_file_tree_status(:empty), do: 2
  defp encode_file_tree_status(:ready), do: 3
  defp encode_file_tree_status({:error, _reason}), do: 4

  @spec error_reason(FileTree.status()) :: String.t()
  defp error_reason({:error, reason}), do: reason
  defp error_reason(_status), do: ""

  @spec file_tree_row_flags(Row.t(), FileTree.t()) :: non_neg_integer()
  defp file_tree_row_flags(%Row{} = row, %FileTree{} = model) do
    0
    |> Wire.maybe_flag(row.flags.directory?, 0)
    |> Wire.maybe_flag(row.flags.expanded?, 1)
    |> Wire.maybe_flag(row.id == model.selected_id, 2)
    |> Wire.maybe_flag(model.focused?, 3)
    |> Wire.maybe_flag(row.flags.active?, 4)
    |> Wire.maybe_flag(row.flags.dirty?, 5)
    |> Wire.maybe_flag(row.editing != nil, 6)
    |> Wire.maybe_flag(row.flags.last_child?, 7)
  end

  @spec encode_editing_type(atom()) :: non_neg_integer()
  defp encode_editing_type(:new_file), do: 0
  defp encode_editing_type(:new_folder), do: 1
  defp encode_editing_type(:rename), do: 2

  @spec encode_git_status(Row.git_status() | nil) :: non_neg_integer()
  defp encode_git_status(nil), do: 0
  defp encode_git_status(:modified), do: 1
  defp encode_git_status(:staged), do: 2
  defp encode_git_status(:untracked), do: 3
  defp encode_git_status(:conflict), do: 4
  defp encode_git_status(:renamed), do: 5
  defp encode_git_status(:deleted), do: 6
end
