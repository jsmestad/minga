defmodule Minga.Frontend.Adapter.GUI.GitStatusEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Protocol.Encoding
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.GitStatus

  @op_gui_git_status Opcodes.gui_git_status()

  @max_u16 65_535

  @spec encode(GitStatus.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%GitStatus{} = model, %Caches{} = caches) do
    fp = :erlang.phash2(model)

    if fp != caches.last_git_status_fp do
      cmd = encode_git_status_binary(model)
      {cmd, %{caches | last_git_status_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_git_status_binary(GitStatus.t()) :: binary()
  defp encode_git_status_binary(%GitStatus{} = model) do
    repo_state_byte = encode_repo_state(model.repo_state)
    syncing_byte = Encoding.bool_to_byte(model.syncing)
    branch_bytes = :erlang.iolist_to_binary([model.branch || ""])
    entry_count = length(model.entries)

    entry_binaries =
      Enum.map(model.entries, fn entry ->
        path_bytes = :erlang.iolist_to_binary([entry.path])
        path_hash = :erlang.phash2(entry.path, 0xFFFFFFFF)
        section = encode_status_section(entry)
        status = encode_file_status(entry.status)

        <<path_hash::32, section::8, status::8, byte_size(path_bytes)::16, path_bytes::binary>>
      end)

    toast_binary = encode_git_toast(model.git_toast)

    entry_base_path_bytes =
      Encoding.utf8_prefix_bytes(model.entry_base_path || "", @max_u16)

    last_commit_message_bytes =
      Encoding.utf8_prefix_bytes(model.last_commit_message || "", @max_u16)

    stash_count = min(model.stash_count || 0, @max_u16)

    IO.iodata_to_binary([
      <<@op_gui_git_status, repo_state_byte::8, syncing_byte::8, model.ahead::16,
        model.behind::16, byte_size(branch_bytes)::16, branch_bytes::binary, entry_count::16>>,
      entry_binaries,
      toast_binary,
      <<byte_size(entry_base_path_bytes)::16, entry_base_path_bytes::binary,
        byte_size(last_commit_message_bytes)::16, last_commit_message_bytes::binary,
        stash_count::16>>
    ])
  end

  @spec encode_git_toast(GitStatus.toast() | nil) :: binary()
  defp encode_git_toast(nil), do: <<0::8>>

  defp encode_git_toast(%{message: message, level: level, action: action}) do
    level_byte = encode_toast_level(level)
    action_byte = encode_toast_action(action)
    msg_bytes = :erlang.iolist_to_binary([message])
    <<1::8, level_byte::8, action_byte::8, byte_size(msg_bytes)::16, msg_bytes::binary>>
  end

  @spec encode_toast_level(:success | :error) :: non_neg_integer()
  defp encode_toast_level(:success), do: 0
  defp encode_toast_level(:error), do: 1

  @spec encode_toast_action(GitStatus.toast_action()) :: non_neg_integer()
  defp encode_toast_action(nil), do: 0
  defp encode_toast_action(:pull_and_retry), do: 1

  @spec encode_repo_state(GitStatus.repo_state()) :: non_neg_integer()
  defp encode_repo_state(:normal), do: 0
  defp encode_repo_state(:not_a_repo), do: 1
  defp encode_repo_state(:loading), do: 2

  @spec encode_status_section(GitStatus.file_entry()) :: non_neg_integer()
  defp encode_status_section(%{staged: true}), do: 0
  defp encode_status_section(%{status: :untracked}), do: 2
  defp encode_status_section(%{status: :conflict}), do: 3
  defp encode_status_section(_), do: 1

  @spec encode_file_status(atom()) :: non_neg_integer()
  defp encode_file_status(:modified), do: 1
  defp encode_file_status(:added), do: 2
  defp encode_file_status(:deleted), do: 3
  defp encode_file_status(:renamed), do: 4
  defp encode_file_status(:copied), do: 5
  defp encode_file_status(:untracked), do: 6
  defp encode_file_status(:conflict), do: 7
  defp encode_file_status(:unknown), do: 0
end
