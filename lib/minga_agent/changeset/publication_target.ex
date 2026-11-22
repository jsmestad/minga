defmodule MingaAgent.Changeset.PublicationTarget do
  @moduledoc """
  Resolves where publishing a staged change touches the project, and refuses targets outside the project root.

  Publication must never write or delete outside the project. A project-relative path can still leave the root through a symlink, either a directory component (`vendor -> /elsewhere`) or the final component (`config.txt -> /etc/config.txt`). This module follows every symlink in the target the same way the operating system would, including dangling links, and requires the result to stay strictly under the real path of the project root. Symlinks that resolve inside the root are allowed.

  Resolution reads the file system through the publication's `Minga.Buffer.Persistence.FileSystem` module, so the same backend that performs the write also answers the containment question.

  The check narrows but does not close a time-of-check to time-of-use window: a process that can modify the project may replace a directory with a symlink after resolution and before the write's own system calls. Closing it fully requires descriptor-relative (`openat` with `O_NOFOLLOW`) operations that the BEAM file API does not expose.
  """

  @max_symlink_depth 40

  @typedoc "File-system backend and its options, as configured for publication."
  @type publication :: {module(), keyword()}

  @typedoc "Why a publication target was refused or could not be resolved."
  @type error :: :outside_project_root | :eloop | term()

  @doc """
  Returns the real path that a write to `relative_path` must replace.

  Every symlink is followed. A missing tail is allowed, because publication may create new files and directories, but the existing part must resolve inside the project root.
  """
  @spec write_path(String.t(), String.t(), publication()) :: {:ok, String.t()} | {:error, error()}
  def write_path(project_root, relative_path, {file_system, opts})
      when is_binary(project_root) and is_binary(relative_path) do
    with {:ok, real_root} <- real_root(file_system, project_root, opts),
         {:ok, target} <- resolve_relative(file_system, real_root, relative_path, opts) do
      require_inside(target, real_root)
    end
  end

  @doc """
  Returns the directory entry that deleting `relative_path` must unlink.

  The parent directory is fully resolved and the final component is kept, so deleting an in-root symlink removes the link rather than its target. The final component's own resolution must also stay inside the project root.
  """
  @spec remove_path(String.t(), String.t(), publication()) ::
          {:ok, String.t()} | {:error, error()}
  def remove_path(project_root, relative_path, {file_system, opts})
      when is_binary(project_root) and is_binary(relative_path) do
    parent = Path.dirname(relative_path)
    name = Path.basename(relative_path)

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

  @spec require_inside(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :outside_project_root}
  defp require_inside(path, "/") when path != "/", do: {:ok, path}

  defp require_inside(path, real_root) do
    if String.starts_with?(path, real_root <> "/"),
      do: {:ok, path},
      else: {:error, :outside_project_root}
  end
end
