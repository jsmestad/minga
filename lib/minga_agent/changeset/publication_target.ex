defmodule MingaAgent.Changeset.PublicationTarget do
  @moduledoc """
  Resolves where staging reads or publishing writes touch the project, and refuses targets outside the project root.

  Publication must never write or delete outside the project, and staging must never read file content from outside it. A project-relative path can still leave the root through a symlink, either a directory component (`vendor -> /elsewhere`) or the final component (`config.txt -> /etc/config.txt`). This module follows every symlink in the target the same way the operating system would, including dangling links, and requires the result to stay strictly under the real path of the project root. Symlinks that resolve inside the root are allowed.

  Resolution reads the file system through the given `Minga.Buffer.Persistence.FileSystem` module, so the same backend that performs the read or write also answers the containment question.

  The check narrows but does not close a time-of-check to time-of-use window: a process that can modify the project may replace a directory with a symlink after resolution and before the write's own system calls. Closing it fully requires descriptor-relative (`openat` with `O_NOFOLLOW`) operations that the BEAM file API does not expose.
  """

  @max_symlink_depth 40

  @typedoc "File-system backend and its options, as configured for publication."
  @type publication :: {module(), keyword()}

  @typedoc "Why a publication target was refused or could not be resolved."
  @type error :: :outside_project_root | :invalid_path | :eloop | term()

  @doc """
  Returns the real path that a write to `relative_path` must replace.

  Every symlink is followed. A missing tail is allowed, because publication may create new files and directories, but the existing part must resolve inside the project root.
  """
  @spec write_path(String.t(), String.t(), publication()) :: {:ok, String.t()} | {:error, error()}
  def write_path(project_root, relative_path, publication)
      when is_binary(project_root) and is_binary(relative_path) do
    resolve_inside(project_root, relative_path, publication)
  end

  @doc """
  Returns the real path that reading `relative_path` from the project must open.

  Every symlink is followed. A missing tail resolves to the path where the file would be, so the caller's own read reports `:enoent`. The existing part must resolve inside the project root; a path that leaves it returns `{:error, :outside_project_root}` before any content is read.
  """
  @spec read_path(String.t(), String.t(), publication()) :: {:ok, String.t()} | {:error, error()}
  def read_path(project_root, relative_path, file_system)
      when is_binary(project_root) and is_binary(relative_path) do
    resolve_inside(project_root, relative_path, file_system)
  end

  @spec resolve_inside(String.t(), String.t(), publication()) ::
          {:ok, String.t()} | {:error, error()}
  defp resolve_inside(project_root, relative_path, {file_system, opts}) do
    with {:ok, real_root} <- real_root(file_system, project_root, opts),
         {:ok, target} <- resolve_relative(file_system, real_root, relative_path, opts) do
      require_inside(target, real_root)
    end
  end

  @doc """
  Returns the project-relative path and the real path that an absolute `path` names after every symlink is followed.

  Use this for absolute paths from an untrusted source, such as a language-server URI. The path is resolved from the file-system root, so a project root that is itself reached through a symlink still matches. The real path must stay strictly inside the real path of the project root, and the relative path is relative to that real root. Read the checked file through the returned real path, not through the untrusted `path`, so that a symlink swapped in after the check cannot redirect the read. A path that is not absolute is refused with `:invalid_path`. A missing tail is allowed, as in `write_path/3`.
  """
  @spec relative_path(String.t(), String.t(), publication()) ::
          {:ok, {relative :: String.t(), real :: String.t()}} | {:error, error()}
  def relative_path(project_root, path, {file_system, opts})
      when is_binary(project_root) and is_binary(path) do
    with :ok <- require_absolute(path),
         {:ok, real_root} <- real_root(file_system, project_root, opts),
         {:ok, real_path} <- walk(file_system, Path.split(path), "/", 0, opts),
         {:ok, target} <- require_inside(real_path, real_root) do
      {:ok, {Path.relative_to(target, real_root), target}}
    end
  end

  @doc """
  Returns the directory entry that deleting `relative_path` must unlink.

  The parent directory is fully resolved and the final component is kept, so deleting an in-root symlink removes the link rather than its target. The final component's own resolution must also stay inside the project root. A final name of `.`, `..`, or an empty path names no entry and is refused with `:invalid_path`.
  """
  @spec remove_path(String.t(), String.t(), publication()) ::
          {:ok, String.t()} | {:error, error()}
  def remove_path(project_root, relative_path, publication)
      when is_binary(project_root) and is_binary(relative_path) do
    case Path.basename(relative_path) do
      name when name in ["", ".", ".."] ->
        {:error, :invalid_path}

      name ->
        remove_entry(project_root, Path.dirname(relative_path), name, publication)
    end
  end

  @spec remove_entry(String.t(), String.t(), String.t(), publication()) ::
          {:ok, String.t()} | {:error, error()}
  defp remove_entry(project_root, parent, name, {file_system, opts}) do
    with {:ok, real_root} <- real_root(file_system, project_root, opts),
         {:ok, real_parent} <- resolve_relative(file_system, real_root, parent, opts),
         {:ok, target} <- walk(file_system, [name], real_parent, 0, opts),
         {:ok, _target} <- require_inside(target, real_root) do
      require_inside(Path.join(real_parent, name), real_root)
    end
  end

  @spec real_root(module(), String.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  defp real_root(file_system, project_root, opts) do
    walk(file_system, Path.split(Path.expand(project_root)), "/", 0, opts)
  end

  @spec resolve_relative(module(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, error()}
  defp resolve_relative(file_system, real_root, relative_path, opts) do
    walk(file_system, Path.split(relative_path), real_root, 0, opts)
  end

  # `current` is always a real path: it contains no symlinks, so `..` can be
  # applied lexically to it.
  @spec walk(module(), [String.t()], String.t(), non_neg_integer(), keyword()) ::
          {:ok, String.t()} | {:error, error()}
  defp walk(_file_system, [], current, _depth, _opts), do: {:ok, current}

  defp walk(file_system, ["/" | rest], _current, depth, opts),
    do: walk(file_system, rest, "/", depth, opts)

  defp walk(file_system, ["." | rest], current, depth, opts),
    do: walk(file_system, rest, current, depth, opts)

  defp walk(file_system, [".." | rest], current, depth, opts),
    do: walk(file_system, rest, Path.dirname(current), depth, opts)

  defp walk(file_system, [component | rest], current, depth, opts) do
    candidate = Path.join(current, component)

    case file_system.lstat(candidate, opts) do
      {:ok, %File.Stat{type: :symlink}} ->
        follow(file_system, candidate, rest, current, depth, opts)

      {:ok, %File.Stat{}} ->
        walk(file_system, rest, candidate, depth, opts)

      {:error, :enoent} ->
        missing_tail(candidate, rest)

      {:error, _reason} = error ->
        error
    end
  end

  @spec follow(module(), String.t(), [String.t()], String.t(), non_neg_integer(), keyword()) ::
          {:ok, String.t()} | {:error, error()}
  defp follow(_file_system, _link, _rest, _current, @max_symlink_depth, _opts),
    do: {:error, :eloop}

  defp follow(file_system, link, rest, current, depth, opts) do
    case file_system.read_link(link, opts) do
      {:ok, target} -> walk(file_system, Path.split(target) ++ rest, current, depth + 1, opts)
      {:error, _reason} = error -> error
    end
  end

  # Nothing under a missing entry exists, so the rest cannot contain a symlink.
  # A `..` after a missing entry fails in the operating system as well.
  @spec missing_tail(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, :enoent}
  defp missing_tail(candidate, rest) do
    names = Enum.reject(rest, &(&1 == "."))

    if ".." in names, do: {:error, :enoent}, else: {:ok, Path.join([candidate | names])}
  end

  @spec require_absolute(String.t()) :: :ok | {:error, :invalid_path}
  defp require_absolute(path) do
    if Path.type(path) == :absolute, do: :ok, else: {:error, :invalid_path}
  end

  @spec require_inside(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :outside_project_root}
  defp require_inside(path, "/") when path != "/", do: {:ok, path}

  defp require_inside(path, real_root) do
    if String.starts_with?(path, real_root <> "/"),
      do: {:ok, path},
      else: {:error, :outside_project_root}
  end
end
