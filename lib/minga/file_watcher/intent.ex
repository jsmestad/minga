defmodule Minga.FileWatcher.Intent do
  @moduledoc """
  Declarative file and project-directory registrations over expanded paths.

  A file registration covers only that path; a project-directory registration
  covers the directory itself and its descendants. Native watcher directories
  are derived from both sets and do not determine which events are covered.
  """

  defstruct files: MapSet.new(), project_dirs: MapSet.new()

  @type t :: %__MODULE__{files: MapSet.t(String.t()), project_dirs: MapSet.t(String.t())}

  @spec new([String.t()], [String.t()]) :: t()
  def new(files, project_dirs) do
    %__MODULE__{files: MapSet.new(files), project_dirs: MapSet.new(project_dirs)}
  end

  @spec watch_path(t(), String.t()) :: t()
  def watch_path(%__MODULE__{} = intent, path),
    do: %__MODULE__{intent | files: MapSet.put(intent.files, path)}

  @spec unwatch_path(t(), String.t()) :: t()
  def unwatch_path(%__MODULE__{} = intent, path),
    do: %__MODULE__{intent | files: MapSet.delete(intent.files, path)}

  @spec watch_directory(t(), String.t()) :: t()
  def watch_directory(%__MODULE__{} = intent, path),
    do: %__MODULE__{intent | project_dirs: MapSet.put(intent.project_dirs, path)}

  @spec unwatch_directory(t(), String.t()) :: t()
  def unwatch_directory(%__MODULE__{} = intent, path),
    do: %__MODULE__{intent | project_dirs: MapSet.delete(intent.project_dirs, path)}

  @spec unwatch_directory_tree(t(), String.t()) :: t()
  def unwatch_directory_tree(%__MODULE__{} = intent, root) do
    project_dirs = MapSet.reject(intent.project_dirs, &under_root?(&1, root))
    %__MODULE__{intent | project_dirs: project_dirs}
  end

  @spec native_dirs(t()) :: MapSet.t(String.t())
  def native_dirs(%__MODULE__{} = intent) do
    intent.files
    |> MapSet.new(&Path.dirname/1)
    |> MapSet.union(intent.project_dirs)
  end

  @spec covers?(t(), String.t()) :: boolean()
  def covers?(%__MODULE__{} = intent, path) do
    MapSet.member?(intent.files, path) or
      Enum.any?(intent.project_dirs, &under_root?(path, &1))
  end

  @spec under_root?(String.t(), String.t()) :: boolean()
  defp under_root?(path, root) when path == root, do: true
  defp under_root?("/" <> _rest, "/"), do: true

  defp under_root?(path, root) do
    root_size = byte_size(root)
    match?(<<^root::binary-size(^root_size), "/", _::binary>>, path)
  end
end
