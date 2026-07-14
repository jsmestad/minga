defmodule Minga.Project.Root do
  @moduledoc """
  Identifies the kind and authorization of a project root.

  Recursive project features accept only explicit directory roots. Broad roots such as the user's home directory, the filesystem root, and mounted-volume roots additionally require confirmation from the user flow that created the value.
  """

  @enforce_keys [:kind, :path]
  defstruct [:kind, :path, broad_root_confirmed?: false]

  @typedoc "The filesystem object represented by a root."
  @type kind :: :file | :directory

  @typedoc "A project root with explicit kind and broad-root authorization."
  @type t :: %__MODULE__{
          kind: kind(),
          path: String.t(),
          broad_root_confirmed?: boolean()
        }

  @typedoc "Why a root cannot authorize recursive project behavior."
  @type error :: :not_a_directory | :broad_root_confirmation_required | :not_a_directory_root

  @doc "Builds a file-scoped root that cannot authorize recursive inventory."
  @spec file(String.t()) :: t()
  def file(path) when is_binary(path) do
    %__MODULE__{kind: :file, path: Path.expand(path)}
  end

  @doc "Builds an explicit directory workspace root."
  @spec directory(String.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def directory(path, opts \\ []) when is_binary(path) and is_list(opts) do
    expanded = Path.expand(path)
    confirmed? = Keyword.get(opts, :broad_root_confirmed, false)

    build_directory(expanded, confirmed?, File.dir?(expanded), broad_path?(expanded))
  end

  @doc "Returns the authorized path for recursive inventory."
  @spec inventory_path(t()) :: {:ok, String.t()} | {:error, error()}
  def inventory_path(%__MODULE__{kind: :directory, path: path, broad_root_confirmed?: confirmed?}) do
    build_inventory_path(path, confirmed?, File.dir?(path), broad_path?(path))
  end

  def inventory_path(%__MODULE__{}), do: {:error, :not_a_directory_root}

  @doc "Returns true when a path names a root whose recursive traversal needs explicit confirmation."
  @spec broad_path?(String.t()) :: boolean()
  def broad_path?(path) when is_binary(path) do
    expanded = Path.expand(path)
    expanded == Path.expand("~") or broad_segments?(Path.split(expanded))
  end

  @spec build_directory(String.t(), boolean(), boolean(), boolean()) ::
          {:ok, t()} | {:error, error()}
  defp build_directory(_path, _confirmed?, false, _broad?), do: {:error, :not_a_directory}

  defp build_directory(_path, false, true, true),
    do: {:error, :broad_root_confirmation_required}

  defp build_directory(path, confirmed?, true, _broad?) do
    {:ok, %__MODULE__{kind: :directory, path: path, broad_root_confirmed?: confirmed?}}
  end

  @spec build_inventory_path(String.t(), boolean(), boolean(), boolean()) ::
          {:ok, String.t()} | {:error, error()}
  defp build_inventory_path(_path, _confirmed?, false, _broad?), do: {:error, :not_a_directory}

  defp build_inventory_path(_path, false, true, true),
    do: {:error, :broad_root_confirmation_required}

  defp build_inventory_path(path, _confirmed?, true, _broad?), do: {:ok, path}

  @spec broad_segments?([String.t()]) :: boolean()
  defp broad_segments?(["/"]), do: true
  defp broad_segments?(["/", "Volumes", _volume]), do: true
  defp broad_segments?(["/", "mnt", _volume]), do: true
  defp broad_segments?(["/", "media", _volume]), do: true
  defp broad_segments?(["/", "run", "media", _user, _volume]), do: true
  defp broad_segments?(_segments), do: false
end
