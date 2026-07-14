defmodule Minga.Project.Root do
  @moduledoc """
  Identifies the kind and authorization of a project root.

  Recursive project features accept only explicit directory roots. Broad roots such as the user's home directory, the filesystem root, and mounted-volume roots additionally require confirmation from the user flow that created the value. Directory paths are canonicalized so symlink aliases cannot bypass that boundary.
  """

  @max_symlink_depth 40

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
  @type error ::
          :not_a_directory
          | :broad_root_confirmation_required
          | :invalid_broad_root_confirmation
          | :not_a_directory_root
          | :root_changed

  @typedoc "Why a filesystem path could not be canonicalized."
  @type canonical_error :: File.posix() | :too_many_symlinks

  @typedoc "Why a workspace-relative file path could not be authorized."
  @type file_error ::
          error()
          | canonical_error()
          | :absolute_path
          | :parent_traversal
          | :outside_workspace

  @doc "Builds a file-scoped root that cannot authorize recursive inventory."
  @spec file(String.t()) :: t()
  def file(path) when is_binary(path) do
    expanded = Path.expand(path)

    canonical =
      case canonical_path(expanded) do
        {:ok, resolved} -> resolved
        {:error, _reason} -> expanded
      end

    %__MODULE__{kind: :file, path: canonical}
  end

  @doc "Builds an explicit directory workspace root."
  @spec directory(String.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def directory(path, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, confirmed?} <- confirmation(Keyword.get(opts, :broad_root_confirmed, false)),
         {:ok, canonical} <- canonical_directory(path),
         :ok <- authorize_broad_root(canonical, confirmed?) do
      {:ok,
       %__MODULE__{
         kind: :directory,
         path: canonical,
         broad_root_confirmed?: confirmed?
       }}
    else
      {:error, :invalid_broad_root_confirmation} = error -> error
      {:error, :broad_root_confirmation_required} = error -> error
      {:error, _reason} -> {:error, :not_a_directory}
    end
  end

  @doc "Returns the authorized canonical path for recursive inventory."
  @spec inventory_path(t()) :: {:ok, String.t()} | {:error, error()}
  def inventory_path(%__MODULE__{kind: :directory, path: path, broad_root_confirmed?: confirmed?}) do
    with {:ok, valid_confirmation?} <- confirmation(confirmed?),
         {:ok, canonical} <- canonical_directory(path),
         :ok <- unchanged_root(path, canonical),
         :ok <- authorize_broad_root(canonical, valid_confirmation?) do
      {:ok, canonical}
    else
      {:error, :invalid_broad_root_confirmation} = error -> error
      {:error, :root_changed} = error -> error
      {:error, :broad_root_confirmation_required} = error -> error
      {:error, _reason} -> {:error, :not_a_directory}
    end
  end

  def inventory_path(%__MODULE__{}), do: {:error, :not_a_directory_root}

  @doc "Resolves an existing workspace-relative path inside an authorized directory root."
  @spec resolve_file(t(), String.t()) :: {:ok, String.t()} | {:error, file_error()}
  def resolve_file(%__MODULE__{} = root, relative_path) when is_binary(relative_path) do
    with {:ok, canonical_root} <- inventory_path(root),
         :ok <- require_relative_path(relative_path),
         {:ok, safe_relative} <- safe_relative_path(relative_path, canonical_root),
         {:ok, canonical_target} <- canonical_path(Path.join(canonical_root, safe_relative)),
         :ok <- authorize_contained_target(canonical_target, canonical_root) do
      {:ok, canonical_target}
    end
  end

  @doc "Returns the canonical target of an existing filesystem path."
  @spec canonical_path(String.t()) :: {:ok, String.t()} | {:error, canonical_error()}
  def canonical_path(path) when is_binary(path) do
    path
    |> Path.expand()
    |> canonical_path([], 0)
  end

  @doc "Returns true when a path names a root whose recursive traversal needs explicit confirmation."
  @spec broad_path?(String.t()) :: boolean()
  def broad_path?(path) when is_binary(path) do
    expanded = Path.expand(path)
    expanded == canonical_home() or broad_segments?(Path.split(expanded))
  end

  @spec canonical_home() :: String.t()
  defp canonical_home do
    expanded_home = Path.expand("~")

    case canonical_path(expanded_home) do
      {:ok, canonical} -> canonical
      {:error, _reason} -> expanded_home
    end
  end

  @spec canonical_directory(String.t()) :: {:ok, String.t()} | {:error, canonical_error()}
  defp canonical_directory(path) do
    case canonical_path(path) do
      {:ok, canonical} -> existing_directory(canonical, File.dir?(canonical))
      {:error, reason} -> {:error, reason}
    end
  end

  @spec existing_directory(String.t(), boolean()) ::
          {:ok, String.t()} | {:error, :enotdir}
  defp existing_directory(path, true), do: {:ok, path}
  defp existing_directory(_path, false), do: {:error, :enotdir}

  @spec require_relative_path(String.t()) :: :ok | {:error, :absolute_path}
  defp require_relative_path(path) do
    case Path.type(path) do
      :relative -> :ok
      _absolute_or_volume_relative -> {:error, :absolute_path}
    end
  end

  @spec safe_relative_path(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :parent_traversal}
  defp safe_relative_path(path, canonical_root) do
    lexical_target = Path.expand(path, canonical_root)
    relative_target = Path.relative_to(lexical_target, canonical_root)

    case Path.type(relative_target) do
      :relative -> {:ok, relative_target}
      _outside -> {:error, :parent_traversal}
    end
  end

  @spec authorize_contained_target(String.t(), String.t()) ::
          :ok | {:error, :outside_workspace}
  defp authorize_contained_target(canonical_target, canonical_root) do
    relative_target = Path.relative_to(canonical_target, canonical_root)

    case Path.safe_relative(relative_target, canonical_root) do
      {:ok, _relative} -> :ok
      :error -> {:error, :outside_workspace}
    end
  end

  @spec confirmation(term()) :: {:ok, boolean()} | {:error, :invalid_broad_root_confirmation}
  defp confirmation(true), do: {:ok, true}
  defp confirmation(false), do: {:ok, false}
  defp confirmation(_value), do: {:error, :invalid_broad_root_confirmation}

  @spec authorize_broad_root(String.t(), boolean()) ::
          :ok | {:error, :broad_root_confirmation_required}
  defp authorize_broad_root(path, confirmed?) do
    broad_root_authorization(broad_path?(path), confirmed?)
  end

  @spec broad_root_authorization(boolean(), boolean()) ::
          :ok | {:error, :broad_root_confirmation_required}
  defp broad_root_authorization(false, _confirmed?), do: :ok
  defp broad_root_authorization(true, true), do: :ok
  defp broad_root_authorization(true, false), do: {:error, :broad_root_confirmation_required}

  @spec unchanged_root(String.t(), String.t()) :: :ok | {:error, :root_changed}
  defp unchanged_root(path, path), do: :ok
  defp unchanged_root(_authorized_path, _current_path), do: {:error, :root_changed}

  @spec canonical_path(String.t(), [String.t()], non_neg_integer()) ::
          {:ok, String.t()} | {:error, canonical_error()}
  defp canonical_path(_path, _seen, depth) when depth >= @max_symlink_depth,
    do: {:error, :too_many_symlinks}

  defp canonical_path(path, seen, depth) do
    {anchor, parts} = split_anchor(path)
    resolve_components(parts, anchor, seen, depth)
  end

  @spec resolve_components([String.t()], String.t(), [String.t()], non_neg_integer()) ::
          {:ok, String.t()} | {:error, canonical_error()}
  defp resolve_components([], current, _seen, _depth), do: {:ok, current}

  defp resolve_components([part | rest], current, seen, depth) do
    candidate = Path.join(current, part)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} -> resolve_symlink(candidate, rest, seen, depth)
      {:ok, _stat} -> resolve_components(rest, candidate, seen, depth)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec resolve_symlink(String.t(), [String.t()], [String.t()], non_neg_integer()) ::
          {:ok, String.t()} | {:error, canonical_error()}
  defp resolve_symlink(candidate, rest, seen, depth) do
    if candidate in seen do
      {:error, :too_many_symlinks}
    else
      case File.read_link(candidate) do
        {:ok, target} ->
          resolved_target = Path.expand(target, Path.dirname(candidate))
          combined = Enum.reduce(rest, resolved_target, &Path.join(&2, &1))
          canonical_path(combined, [candidate | seen], depth + 1)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec split_anchor(String.t()) :: {String.t(), [String.t()]}
  defp split_anchor(path) do
    case Path.split(path) do
      [anchor | parts] -> {anchor, parts}
      [] -> {path, []}
    end
  end

  @spec broad_segments?([String.t()]) :: boolean()
  defp broad_segments?(["/"]), do: true
  defp broad_segments?(["/", "Volumes", _volume]), do: true
  defp broad_segments?(["/", "mnt", _volume]), do: true
  defp broad_segments?(["/", "media", _volume]), do: true
  defp broad_segments?(["/", "run", "media", _user, _volume]), do: true
  defp broad_segments?(_segments), do: false
end
