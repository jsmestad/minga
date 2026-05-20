defmodule MingaEditor.State.Workspace.Persistence do
  @moduledoc """
  Persists editor workspaces under the active project root.

  Workspace persistence is per project and current-state oriented: each workspace gets one JSON file in `.minga/workspaces/`. Writes are atomic, using a sibling `.tmp` file followed by `File.rename/2`, so a crash leaves either the previous complete file or the new complete file.
  """

  alias MingaEditor.State.Workspace

  @workspace_dir [".minga", "workspaces"]

  @type write_opt :: {:rename, (Path.t(), Path.t() -> :ok | {:error, term()})}

  @doc "Writes a workspace JSON file under the project root. Returns `:ok` when persistence is disabled."
  @spec write(Workspace.t(), String.t() | nil) :: :ok | {:error, term()}
  def write(workspace, project_root), do: write(workspace, project_root, [])

  @doc false
  @spec write(Workspace.t(), String.t() | nil, [write_opt()]) :: :ok | {:error, term()}
  def write(%Workspace{} = workspace, project_root, opts) do
    with {:ok, root} <- normalize_project_root(project_root),
         :ok <- File.mkdir_p(workspace_dir(root)),
         :ok <-
           atomic_write(
             path_for(root, workspace.id),
             JSON.encode!(Workspace.to_persisted_map(workspace)),
             opts
           ) do
      :ok
    else
      :disabled -> :ok
      {:error, reason} = error -> log_write_error(project_root, workspace.id, reason, error)
    end
  end

  @doc "Reads one workspace JSON file. Unknown fields are ignored and missing fields use workspace defaults."
  @spec read(Path.t(), String.t()) :: {:ok, Workspace.t()} | {:error, term()}
  def read(path, project_root) when is_binary(path) and is_binary(project_root) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- JSON.decode(content) do
      Workspace.from_persisted_map(data, project_root)
    end
  end

  @doc "Scans `.minga/workspaces/*.json` and returns valid workspaces sorted by id. Corrupt files are skipped with a warning."
  @spec scan(String.t() | nil) :: [Workspace.t()]
  def scan(project_root) do
    case normalize_project_root(project_root) do
      {:ok, root} -> scan_root(root)
      :disabled -> []
    end
  end

  @doc "Deletes one persisted workspace file. Returns `:ok` when persistence is disabled or the file is absent."
  @spec delete(non_neg_integer(), String.t() | nil) :: :ok | {:error, term()}
  def delete(id, project_root) when is_integer(id) and id >= 0 do
    case normalize_project_root(project_root) do
      {:ok, root} -> delete_path(path_for(root, id))
      :disabled -> :ok
    end
  end

  @doc false
  @spec path_for(String.t(), non_neg_integer()) :: Path.t()
  def path_for(project_root, id) when is_binary(project_root) and is_integer(id) and id >= 0 do
    project_root
    |> workspace_dir()
    |> Path.join("#{id}.json")
  end

  @spec scan_root(String.t()) :: [Workspace.t()]
  defp scan_root(root) do
    root
    |> workspace_dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(&read_scanned_file(&1, root))
    |> Enum.sort_by(& &1.id)
  end

  @spec read_scanned_file(Path.t(), String.t()) :: [Workspace.t()]
  defp read_scanned_file(path, root) do
    case read(path, root) do
      {:ok, workspace} -> [workspace]
      {:error, reason} -> log_scan_warning(path, reason)
    end
  end

  @spec workspace_dir(String.t()) :: Path.t()
  defp workspace_dir(project_root), do: Path.join([project_root | @workspace_dir])

  @spec atomic_write(Path.t(), binary(), [write_opt()]) :: :ok | {:error, term()}
  defp atomic_write(path, content, opts) do
    tmp_path = path <> ".tmp"
    rename = Keyword.get(opts, :rename, &File.rename/2)

    case File.write(tmp_path, content) do
      :ok -> rename.(tmp_path, path)
      {:error, _reason} = error -> error
    end
  end

  @spec normalize_project_root(String.t() | nil) :: {:ok, String.t()} | :disabled
  defp normalize_project_root(project_root) when is_binary(project_root) do
    root = Path.expand(project_root)
    if File.dir?(root), do: {:ok, root}, else: :disabled
  end

  defp normalize_project_root(_project_root), do: :disabled

  @spec delete_path(Path.t()) :: :ok | {:error, term()}
  defp delete_path(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec log_write_error(String.t() | nil, non_neg_integer(), term(), {:error, term()}) ::
          {:error, term()}
  defp log_write_error(project_root, id, reason, error) do
    Minga.Log.warning(
      :editor,
      "Workspace persistence write failed for #{inspect(project_root)}/#{id}: #{inspect(reason)}"
    )

    error
  end

  @spec log_scan_warning(Path.t(), term()) :: []
  defp log_scan_warning(path, reason) do
    Minga.Log.warning(:editor, "Skipping corrupt workspace file #{path}: #{inspect(reason)}")
    []
  end
end
