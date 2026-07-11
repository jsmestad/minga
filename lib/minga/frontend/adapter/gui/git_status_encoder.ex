defmodule Minga.Frontend.Adapter.GUI.GitStatusEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Encode
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.GitStatus

  @op_gui_git_status Opcodes.gui_git_status()

  @spec encode(GitStatus.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%GitStatus{} = model, %Caches{} = caches) do
    fp = :erlang.phash2(model)

    if fp != caches.last_git_status_fp do
      {encode_command(model), %{caches | last_git_status_fp: fp}}
    else
      {nil, caches}
    end
  end

  # The fingerprint/skip-if-unchanged shell stays hand-written; byte production
  # delegates to the schema-generated pure encoder after Writer has checked every
  # bounded numeric and length field in the projected wire model.
  @spec encode_command(GitStatus.t()) :: binary()
  def encode_command(%GitStatus{} = model) do
    wire = to_wire(model)

    :gui_git_status
    |> Writer.new()
    |> preflight(wire)
    |> Writer.append(<<@op_gui_git_status>>)
    |> Writer.append(Encode.encode_gui_git_status(wire))
    |> Writer.finish()
  end

  @spec to_wire(GitStatus.t()) :: map()
  defp to_wire(%GitStatus{} = model) do
    %{
      repo_state: model.repo_state,
      syncing: if(model.syncing, do: 1, else: 0),
      ahead: model.ahead,
      behind: model.behind,
      branch: model.branch,
      entries: model.entries,
      toast: model.git_toast,
      entry_base_path: model.entry_base_path,
      last_commit_message: model.last_commit_message,
      stash_count: model.stash_count
    }
  end

  @spec preflight(Writer.t(), map()) :: Writer.t()
  defp preflight(%Writer{} = writer, wire) do
    writer
    |> Writer.check_uint8(:syncing, wire.syncing)
    |> Writer.check_uint16(:ahead, wire.ahead)
    |> Writer.check_uint16(:behind, wire.behind)
    |> Writer.check_string16(:branch, wire.branch)
    |> Writer.check_uint16(:entry_count, Enum.count(wire.entries))
    |> preflight_entries(wire.entries)
    |> preflight_toast(wire.toast)
    |> Writer.check_string16(:entry_base_path, wire.entry_base_path)
    |> Writer.check_string16(:last_commit_message, wire.last_commit_message)
    |> Writer.check_uint16(:stash_count, wire.stash_count)
  end

  @spec preflight_entries(Writer.t(), [GitStatus.wire_entry()]) :: Writer.t()
  defp preflight_entries(%Writer{} = writer, entries) do
    Enum.reduce(entries, writer, fn entry, acc ->
      acc
      |> Writer.check_uint32(:entry_path_hash, entry.path_hash)
      |> Writer.check_uint8(:entry_section, entry.section)
      |> Writer.check_string16(:entry_path, entry.path)
    end)
  end

  @spec preflight_toast(Writer.t(), GitStatus.wire_toast()) :: Writer.t()
  defp preflight_toast(%Writer{} = writer, %{present: 0}) do
    Writer.check_uint8(writer, :toast_present, 0)
  end

  defp preflight_toast(%Writer{} = writer, %{present: 1} = toast) do
    writer
    |> Writer.check_uint8(:toast_present, 1)
    |> Writer.check_string16(:toast_message, toast.message)
  end
end
