defmodule Minga.Frontend.Adapter.GUI.GitStatusEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
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
  # delegates to the schema-generated pure encoder. The builder has already done
  # every derivation (path hashing, the section predicate, utf8 truncation, the
  # stash clamp, toast normalization), so `to_wire/1` is a thin projection that
  # maps the model's boolean `syncing` to its 0/1 byte and renames fields.
  @spec encode_command(GitStatus.t()) :: binary()
  def encode_command(%GitStatus{} = model) do
    IO.iodata_to_binary([@op_gui_git_status | Encode.encode_gui_git_status(to_wire(model))])
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
end
