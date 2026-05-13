defmodule MingaEditor.UI.Picker.RemoteFileSource do
  @moduledoc "Picker source for opening files from a remote Minga server."

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Distribution.File, as: RemoteFile
  alias Minga.Language
  alias MingaEditor.Commands.RemoteFiles
  alias MingaEditor.UI.Devicon
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Remote files"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: false

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{
        picker_ui: %{context: %{server_name: server_name, node: remote_node, root: root}}
      }) do
    case RemoteFile.list_files(remote_node, root) do
      {:ok, paths} -> Enum.map(paths, &format_candidate(server_name, root, &1))
      {:error, reason} -> log_error(server_name, reason)
    end
  end

  def candidates(_ctx), do: []

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {:remote_file, server_name, path}}, state) do
    RemoteFiles.open_remote_file(state, server_name, path)
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  @spec format_candidate(String.t(), String.t(), String.t()) :: Item.t()
  defp format_candidate(server_name, root, path) do
    filename = Path.basename(path)
    rel_dir = path |> Path.relative_to(root) |> Path.dirname()
    ft = Language.detect_filetype(filename)
    {icon, color} = Devicon.icon_and_color(ft)

    %Item{
      id: {:remote_file, server_name, path},
      label: "#{icon} #{filename}",
      description: "[#{server_name}] #{rel_dir}",
      icon_color: color,
      two_line: true
    }
  end

  @spec log_error(String.t(), term()) :: []
  defp log_error(server_name, reason) do
    Minga.Log.warning(:distribution, "Failed to list files on #{server_name}: #{inspect(reason)}")
    []
  end
end
