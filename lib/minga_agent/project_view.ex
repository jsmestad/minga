defmodule MingaAgent.ProjectView do
  @moduledoc """
  Facade for workspace-local project file access.

  A project view gives agent code one stable API for direct project files and isolated overlay-backed files. Paths are logical paths relative to `project_root`; callers never use frontend labels, tab labels, or backend worktree paths.
  """

  alias MingaAgent.ProjectView
  alias MingaAgent.ProjectView.Direct
  alias MingaAgent.ProjectView.Overlay

  @typedoc "Project view handle."
  @type t :: %__MODULE__{
          id: String.t(),
          project_root: String.t(),
          backend: module(),
          ref: ProjectView.Backend.ref(),
          workspace_id: non_neg_integer() | nil
        }

  @enforce_keys [:id, :project_root, :backend, :ref]
  defstruct [:id, :project_root, :backend, :ref, workspace_id: nil]

  @doc "Creates a direct project view rooted at `project_root`."
  @spec direct(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def direct(project_root, opts \\ []) when is_binary(project_root) do
    Direct.create(project_root, opts)
  end

  @doc "Creates an overlay-backed project view rooted at `project_root`."
  @spec overlay(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def overlay(project_root, opts \\ []) when is_binary(project_root) do
    Overlay.create(project_root, opts)
  end

  @doc "Reads a file from the view."
  @spec read_file(t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(%__MODULE__{} = view, relative_path) when is_binary(relative_path) do
    with {:ok, path} <- normalize_relative_path(relative_path) do
      view.backend.read_file(view, path)
    end
  end

  @doc "Writes a file in the view."
  @spec write_file(t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(%__MODULE__{} = view, relative_path, content)
      when is_binary(relative_path) and is_binary(content) do
    with {:ok, path} <- normalize_relative_path(relative_path) do
      view.backend.write_file(view, path, content)
    end
  end

  @doc "Replaces exact text in a file in the view."
  @spec edit_file(t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def edit_file(%__MODULE__{} = view, relative_path, old_text, new_text)
      when is_binary(relative_path) and is_binary(old_text) and is_binary(new_text) do
    with {:ok, path} <- normalize_relative_path(relative_path) do
      view.backend.edit_file(view, path, old_text, new_text)
    end
  end

  @doc "Deletes a file from the view."
  @spec delete_file(t(), String.t()) :: :ok | {:error, term()}
  def delete_file(%__MODULE__{} = view, relative_path) when is_binary(relative_path) do
    with {:ok, path} <- normalize_relative_path(relative_path) do
      view.backend.delete_file(view, path)
    end
  end

  @doc "Lists a directory in the view."
  @spec list_directory(t(), String.t()) ::
          {:ok, [ProjectView.Backend.directory_entry()]} | {:error, term()}
  def list_directory(%__MODULE__{} = view, relative_path) when is_binary(relative_path) do
    with {:ok, path} <- normalize_relative_path(relative_path, allow_root: true) do
      view.backend.list_directory(view, path)
    end
  end

  @doc "Returns the directory shell commands should run in for this view."
  @spec working_dir(t()) :: String.t()
  def working_dir(%__MODULE__{} = view), do: view.backend.working_dir(view)

  @doc "Returns environment variables shell commands should use for this view."
  @spec command_env(t()) :: [{String.t(), String.t()}]
  def command_env(%__MODULE__{} = view), do: view.backend.command_env(view)

  @doc "Returns backend-specific diff data for the view."
  @spec diff(t()) :: {:ok, [map()]} | {:error, term()}
  def diff(%__MODULE__{} = view), do: view.backend.diff(view)

  @doc "Promotes view-local changes to `target`."
  @spec promote(t(), term()) :: :ok | {:conflict, map()} | {:error, term()}
  def promote(%__MODULE__{} = view, target), do: view.backend.promote(view, target)

  @doc "Discards one file from view-local state."
  @spec discard_file(t(), String.t()) :: :ok | {:error, term()}
  def discard_file(%__MODULE__{} = view, relative_path) when is_binary(relative_path) do
    with {:ok, path} <- normalize_relative_path(relative_path) do
      view.backend.discard_file(view, path)
    end
  end

  @doc "Discards view-local state."
  @spec discard(t()) :: :ok | {:error, term()}
  def discard(%__MODULE__{} = view), do: view.backend.discard(view)

  @doc "Returns capability flags for this view."
  @spec capabilities(t()) :: ProjectView.Backend.capabilities()
  def capabilities(%__MODULE__{} = view), do: view.backend.capabilities(view)

  @doc false
  @spec new(module(), String.t(), ProjectView.Backend.ref(), keyword()) :: t()
  def new(backend, project_root, ref, opts) when is_atom(backend) and is_binary(project_root) do
    %__MODULE__{
      id: Keyword.get_lazy(opts, :id, fn -> unique_id() end),
      project_root: Path.expand(project_root),
      backend: backend,
      ref: ref,
      workspace_id: Keyword.get(opts, :workspace_id)
    }
  end

  @doc false
  @spec normalize_relative_path(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal}
  def normalize_relative_path(path, opts \\ []) when is_binary(path) do
    allow_root? = Keyword.get(opts, :allow_root, false)
    reject_invalid_relative_path(path, normalized_components(path), allow_root?)
  end

  @spec normalized_components(String.t()) :: [String.t()]
  defp normalized_components(path) do
    path
    |> String.trim_leading("./")
    |> Path.split()
    |> Enum.reject(&(&1 in [".", ""]))
  end

  @spec reject_invalid_relative_path(String.t(), [String.t()], boolean()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal}
  defp reject_invalid_relative_path(path, components, allow_root?) do
    if String.starts_with?(path, "/") or Enum.member?(components, "..") do
      {:error, :path_traversal}
    else
      relative_path_from_components(components, allow_root?)
    end
  end

  @spec relative_path_from_components([String.t()], boolean()) ::
          {:ok, String.t()} | {:error, :invalid_path}
  defp relative_path_from_components([], true), do: {:ok, ""}
  defp relative_path_from_components([], false), do: {:error, :invalid_path}
  defp relative_path_from_components(components, _allow_root?), do: {:ok, Path.join(components)}

  @spec unique_id() :: String.t()
  defp unique_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
