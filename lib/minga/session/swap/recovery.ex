defmodule Minga.Session.Swap.Recovery do
  @moduledoc """
  Scans the swap directory for orphaned swap files and determines
  which ones are recoverable.

  A swap file is recoverable when:
  - It parses correctly (valid MINGA_SWAP_V1 header)
  - The OS PID that wrote it is no longer alive (`kill -0` check)
  - The original file still exists on disk

  Swap files written by a still-running Minga instance are left alone.
  Corrupt swap files are cleaned up automatically.
  Recognized generation temporary files are removed only after their owner OS process exits.
  """

  alias Minga.Session.Swap

  @typedoc "A recoverable swap file entry."
  @type entry :: %{
          path: String.t(),
          swap_path: String.t(),
          swap_mtime: integer()
        }

  @typedoc """
  Which recoverable swap files a scan returns.

  `:all` returns every one. `{:project, root}` returns those whose file is inside `root`. `{:file, path}` returns the one for that file. A swap outside the scope keeps its unsaved text on disk until its own project or file is opened: no scan drops unsaved text that it does not return.
  """
  @type scope :: :all | {:project, String.t()} | {:file, String.t()}

  @typedoc "Options for scan and recovery operations. `:roots` applies to `recoverable_projects/1` only."
  @type option ::
          {:swap_dir, String.t()}
          | {:pid_alive?, (integer() -> boolean())}
          | {:scope, scope()}
          | {:roots, [String.t()]}

  @typedoc "Unsaved text waiting in one project. `root` is `nil` for files outside any project."
  @type waiting_project :: %{root: String.t() | nil, files: pos_integer()}

  # `:saved` loses nothing: the file already holds the text.
  # `:unparseable` names no file, so only an unscoped scan removes it.
  # `:left_alone` is a swap that a running editor owns, or one that cannot be read right now.
  @typep verdict ::
           {:recoverable, entry()}
           | {:saved, swap_path :: String.t()}
           | {:unparseable, swap_path :: String.t()}
           | :left_alone

  @doc """
  Scans the swap directory and returns the recoverable entries in scope.

  Each entry contains the original file path, the swap file path,
  and the swap file's mtime. The caller decides what to do with them
  (show a recovery prompt, auto-recover, etc.).

  ## The lifetime of a swap file

  A swap file is never removed for its age. It leaves the disk only when:

  - its text is recovered (`recover/1`) or the user declines it (`discard/1`);
  - the buffer that wrote it is saved, closed, or its editor quits on the user's decision;
  - this scan finds that its owner has exited and the file on disk already holds the same text, so nothing is unsaved;
  - an unscoped scan (`:all`) finds a swap that cannot be parsed and whose owner has exited. This is logged as a warning. A scoped scan leaves it, because it cannot tell whose it is.

  A swap whose file no longer exists, or cannot be read, is still recoverable: the swap is the only copy of that text. A swap that cannot itself be read right now is left alone.

  A swap whose owner is still running belongs to that editor and is left alone.

  ## Options

  - `:swap_dir` - override the default swap directory (for testing)
  - `:pid_alive?` - override the PID liveness check (for testing)
  - `:scope` - which entries to return (default `:all`); see `t:scope/0`
  """
  @spec scan([option()]) :: [entry()]
  def scan(opts \\ []) do
    dir = Swap.swap_dir(opts)
    pid_alive? = Keyword.get(opts, :pid_alive?, &Swap.pid_alive?/1)
    scope = Keyword.get(opts, :scope, :all)

    case File.ls(dir) do
      {:ok, files} ->
        sweep_orphaned_temporary_files(dir, files, pid_alive?)

        dir
        |> verdicts(files, pid_alive?)
        |> Enum.flat_map(&apply_verdict(&1, scope))

      {:error, _} ->
        []
    end
  end

  @doc """
  Lists the projects that have unsaved text waiting in swap files, with the number of files in each.

  It reads the swap directory and removes nothing. A project home or a startup message uses it to say where unsaved text is waiting, so a swap for a project that is not open is never invisible. Files outside any project are counted under a `nil` root.

  Pass `roots:` with the project roots the caller knows (for example its recent projects) to count each file under the deepest of those roots that contains it. Without `roots:`, each file is counted under the nearest project marker above it. A scan with `scope: {:project, root}` returns every file inside `root`, so when one known root contains another, the outer root's count leaves out the files counted under the inner one.
  """
  @spec recoverable_projects([option()]) :: [waiting_project()]
  def recoverable_projects(opts \\ []) do
    dir = Swap.swap_dir(opts)
    pid_alive? = Keyword.get(opts, :pid_alive?, &Swap.pid_alive?/1)

    case File.ls(dir) do
      {:ok, files} ->
        dir
        |> verdicts(files, pid_alive?)
        |> Enum.flat_map(fn
          {:recoverable, entry} -> [project_root(entry.path, Keyword.get(opts, :roots))]
          _removed_or_owned -> []
        end)
        |> Enum.frequencies()
        |> Enum.map(fn {root, count} -> %{root: root, files: count} end)
        |> Enum.sort_by(&{is_nil(&1.root), &1.root})

      {:error, _} ->
        []
    end
  end

  @doc "Deletes a swap file (user declined recovery)."
  @spec discard(String.t()) :: :ok
  def discard(swap_path) when is_binary(swap_path) do
    File.rm(swap_path)
    :ok
  end

  @doc """
  Recovers content from a swap file.

  Returns `{:ok, file_path, content}` where content is the unsaved
  buffer text. The caller is responsible for opening a buffer with
  this content and marking it as dirty. The swap file is deleted
  after successful recovery.
  """
  @spec recover(String.t()) :: {:ok, String.t(), binary()} | {:error, term()}
  def recover(swap_path) when is_binary(swap_path) do
    case Swap.read(swap_path) do
      {:ok, meta, content} ->
        # Best-effort: if this fails the file is cleaned up on next scan.
        File.rm(swap_path)
        {:ok, meta.path, content}

      error ->
        error
    end
  end

  @spec verdicts(String.t(), [String.t()], (integer() -> boolean())) :: [verdict()]
  defp verdicts(dir, files, pid_alive?) do
    files
    |> Enum.filter(&String.ends_with?(&1, ".swap"))
    |> Enum.map(&verdict(Path.join(dir, &1), pid_alive?))
  end

  # Decides what a swap file is, without changing anything on disk.
  @spec verdict(String.t(), (integer() -> boolean())) :: verdict()
  defp verdict(swap_path, pid_alive?) do
    case Swap.read(swap_path) do
      {:ok, meta, content} ->
        if pid_alive?.(meta.os_pid), do: :left_alone, else: orphan_verdict(meta, content)

      {:error, :invalid_format} ->
        if owner_alive?(swap_path, pid_alive?), do: :left_alone, else: {:unparseable, swap_path}

      # The swap exists but cannot be read right now (permissions, an I/O error). It may hold unsaved text.
      {:error, _reason} ->
        :left_alone
    end
  end

  # A swap that cannot be parsed still names its owner in its file name: `<hash>.<os_pid>.swap`.
  # A running editor may have written it in a format this build does not know.
  @spec owner_alive?(String.t(), (integer() -> boolean())) :: boolean()
  defp owner_alive?(swap_path, pid_alive?) do
    with [pid_string] <- Regex.run(~r/\.(\d+)\.swap\z/, swap_path, capture: :all_but_first),
         {os_pid, ""} <- Integer.parse(pid_string) do
      pid_alive?.(os_pid)
    else
      _no_owner_in_name -> false
    end
  end

  @spec orphan_verdict(Swap.metadata(), binary()) :: verdict()
  defp orphan_verdict(meta, content) do
    case File.read(meta.path) do
      {:ok, ^content} ->
        {:saved, meta.swap_path}

      # Different text, a file that no longer exists, or one that cannot be read right now.
      # The swap is the only copy of the unsaved text, so it stays recoverable.
      _different_missing_or_unreadable ->
        {:recoverable, %{path: meta.path, swap_path: meta.swap_path, swap_mtime: meta.mtime}}
    end
  end

  @spec apply_verdict(verdict(), scope()) :: [entry()]
  defp apply_verdict({:recoverable, entry}, scope),
    do: if(in_scope?(entry.path, scope), do: [entry], else: [])

  defp apply_verdict(:left_alone, _scope), do: []

  defp apply_verdict({:saved, swap_path}, _scope) do
    File.rm(swap_path)
    []
  end

  defp apply_verdict({:unparseable, swap_path}, :all) do
    File.rm(swap_path)
    Minga.Log.warning(:editor, "Removed a swap file that cannot be parsed: #{swap_path}")
    []
  end

  defp apply_verdict({:unparseable, _swap_path}, _scope), do: []

  @spec in_scope?(String.t(), scope()) :: boolean()
  defp in_scope?(_path, :all), do: true
  defp in_scope?(path, {:file, file}), do: canonical(path) == canonical(file)
  defp in_scope?(path, {:project, root}), do: inside?(canonical(path), canonical(root))

  @spec inside?(String.t(), String.t()) :: boolean()
  defp inside?(path, root), do: String.starts_with?(path, String.trim_trailing(root, "/") <> "/")

  # Project sessions are keyed by the canonical project root, so swaps are matched the same way.
  # A project opened through a symlink still finds the swaps of its files.
  # A file that no longer exists is placed under the canonical path of its nearest existing directory.
  @spec canonical(String.t()) :: String.t()
  defp canonical(path) do
    expanded = Path.expand(path)

    case Minga.Project.Root.canonical_path(expanded) do
      {:ok, canonical} -> canonical
      {:error, _reason} -> canonical_missing(expanded, Path.dirname(expanded))
    end
  end

  @spec canonical_missing(String.t(), String.t()) :: String.t()
  defp canonical_missing(path, path), do: path
  defp canonical_missing(path, parent), do: Path.join(canonical(parent), Path.basename(path))

  # With known roots, a file belongs to the deepest root that contains it, which is how a scoped scan matches it.
  # Without them, the nearest project marker above the file names its project.
  @spec project_root(String.t(), [String.t()] | nil) :: String.t() | nil
  defp project_root(path, nil) do
    case Minga.Project.Detector.detect(path) do
      {:ok, root, _type} -> canonical(root)
      :none -> nil
    end
  end

  defp project_root(path, roots) when is_list(roots) do
    file = canonical(path)

    roots
    |> Enum.map(&canonical/1)
    |> Enum.filter(&inside?(file, &1))
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  @spec sweep_orphaned_temporary_files(
          String.t(),
          [String.t()],
          (integer() -> boolean())
        ) :: :ok
  defp sweep_orphaned_temporary_files(directory, files, pid_alive?) do
    Enum.each(files, fn filename ->
      maybe_remove_orphaned_temporary_file(directory, filename, pid_alive?)
    end)
  end

  @spec maybe_remove_orphaned_temporary_file(
          String.t(),
          String.t(),
          (integer() -> boolean())
        ) :: :ok
  defp maybe_remove_orphaned_temporary_file(directory, filename, pid_alive?) do
    case Swap.temporary_owner_pid(filename) do
      {:ok, os_pid} -> remove_temporary_file_if_orphaned(directory, filename, os_pid, pid_alive?)
      :error -> :ok
    end
  end

  @spec remove_temporary_file_if_orphaned(
          String.t(),
          String.t(),
          pos_integer(),
          (integer() -> boolean())
        ) :: :ok
  defp remove_temporary_file_if_orphaned(directory, filename, os_pid, pid_alive?) do
    if pid_alive?.(os_pid) do
      :ok
    else
      remove_orphaned_temporary_file(Path.join(directory, filename))
    end
  end

  @spec remove_orphaned_temporary_file(String.t()) :: :ok
  defp remove_orphaned_temporary_file(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Minga.Log.warning(
          :editor,
          "Failed to remove orphaned swap temporary file #{path}: #{inspect(reason)}"
        )
    end
  end
end
