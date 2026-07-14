defmodule Minga.Project.FileFind do
  @moduledoc """
  Discovers files for an explicit directory workspace.

  Recursive discovery accepts `Minga.Project.Root` values rather than path strings. This keeps opened files, detected ancestors, and cwd fallbacks from becoming authorization to inventory a directory.

  Uses the cheapest available tool: `git ls-files` for repository roots, `fd` elsewhere, and `find` as the universal fallback. Every command runs in a cancellable worker that owns and terminates the external process tree.
  """

  alias Minga.Project.FileFind.Worker
  alias Minga.Project.Root

  @typedoc "A file discovery strategy."
  @type strategy :: :fd | :git | :find | :none

  @typedoc "Result of file discovery."
  @type result :: {:ok, [String.t()]} | {:error, String.t()}

  @typedoc "Discovery options shared by synchronous and managed callers."
  @type option ::
          {:timeout, pos_integer()}
          | {:max_output_bytes, pos_integer()}
          | {:max_file_count, pos_integer()}

  @default_timeout_ms 30_000

  @doc "Lists files under an explicit directory workspace root with bounded execution."
  @spec list_files(Root.t(), [option()]) :: result()
  def list_files(root, opts \\ [])

  def list_files(%Root{} = root, opts) when is_list(opts) do
    owner = self()

    case start(root, owner, opts) do
      {:ok, worker} -> await_result(worker, Keyword.get(opts, :timeout, @default_timeout_ms))
      {:error, reason} -> {:error, reason}
    end
  end

  def list_files(_root, _opts),
    do: {:error, "Project inventory requires an explicit directory workspace root"}

  @doc "Starts cancellable discovery for an explicit directory workspace root."
  @spec start(Root.t(), pid(), [option()]) :: {:ok, pid()} | {:error, String.t()}
  def start(root, owner, opts \\ [])

  def start(%Root{} = root, owner, opts) when is_pid(owner) and is_list(opts) do
    with {:ok, path} <- inventory_path(root),
         {:ok, command, strategy} <- command(path) do
      worker_opts = Keyword.take(opts, [:max_output_bytes, :max_file_count])

      Worker.start(
        owner,
        command,
        fn output, status -> parse_result(strategy, output, status) end,
        worker_opts
      )
    else
      {:error, reason} when is_atom(reason) -> {:error, root_error(reason, root.path)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Cancels an in-flight discovery worker and waits for process-tree termination."
  @spec cancel(pid()) :: Worker.cancel_result()
  defdelegate cancel(worker), to: Worker

  @doc "Detects the file-finding strategy for a directory path without starting inventory."
  @spec detect_strategy(String.t()) :: strategy()
  def detect_strategy(root) when is_binary(root) do
    detect_strategy(git_strategy_available?(root), root)
  end

  @spec fd_args([String.t()]) :: [String.t()]
  def fd_args(exclude_list \\ excludes()) do
    exclude_args = Enum.flat_map(exclude_list, &["--exclude", &1])
    ["--type", "f", "--hidden"] ++ Enum.concat(exclude_args, ["."])
  end

  @doc false
  @spec await_result(pid(), pos_integer()) :: result()
  def await_result(worker, timeout) when is_integer(timeout) and timeout > 0 do
    ref = Process.monitor(worker)

    receive do
      {:file_find_done, ^worker, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^worker, reason} ->
        {:error, "Project file discovery stopped: #{inspect(reason)}"}
    after
      timeout ->
        cancel_result = cancel(worker)
        Process.demonitor(ref, [:flush])
        flush_worker_result(worker)
        timeout_error(cancel_result)
    end
  end

  @spec flush_worker_result(pid()) :: :ok
  defp flush_worker_result(worker) do
    receive do
      {:file_find_done, ^worker, _result} -> :ok
    after
      0 -> :ok
    end
  end

  @spec timeout_error(Worker.cancel_result()) :: result()
  defp timeout_error(:ok), do: {:error, "Project file discovery timed out"}

  defp timeout_error({:error, reason}),
    do: {:error, "Project file discovery timed out; #{reason}"}

  @spec inventory_path(Root.t()) :: {:ok, String.t()} | {:error, Root.error()}
  defp inventory_path(root), do: Root.inventory_path(root)

  @spec command(String.t()) :: {:ok, Worker.command(), strategy()} | {:error, String.t()}
  defp command(root) do
    command(detect_strategy(root), root)
  end

  @spec command(strategy(), String.t()) ::
          {:ok, Worker.command(), strategy()} | {:error, String.t()}
  defp command(:git, root) do
    args = ["ls-files", "--cached", "--others", "--exclude-standard"]
    {:ok, {System.find_executable("git"), args, root}, :git}
  end

  defp command(:fd, root) do
    {:ok, {fd_executable(), fd_args(), root}, :fd}
  end

  defp command(:find, root) do
    exclude_args = Enum.flat_map(excludes(), &["-not", "-path", "*/#{&1}/*", "-not", "-name", &1])
    args = [".", "-type", "f"] ++ exclude_args
    {:ok, {System.find_executable("find"), args, root}, :find}
  end

  defp command(:none, _root) do
    {:error, "No file-finding tool available. Install `fd` or `git` for best results."}
  end

  @spec parse_result(strategy(), String.t(), non_neg_integer()) :: result()
  defp parse_result(:fd, output, 0), do: {:ok, parse_lines(output)}
  defp parse_result(:fd, output, _status), do: {:error, "fd failed: #{String.trim(output)}"}

  defp parse_result(:git, output, 0) do
    {:ok, output |> parse_lines() |> filter_excludes()}
  end

  defp parse_result(:git, output, _status),
    do: {:error, "git ls-files failed: #{String.trim(output)}"}

  defp parse_result(:find, output, status) when status in [0, 1],
    do: {:ok, parse_lines(output)}

  defp parse_result(:find, output, _status), do: {:error, "find failed: #{output}"}

  @spec detect_strategy(boolean(), String.t()) :: strategy()
  defp detect_strategy(true, _root), do: :git
  defp detect_strategy(false, root), do: detect_strategy_without_git(root)

  @spec detect_strategy_without_git(String.t()) :: strategy()
  defp detect_strategy_without_git(_root) do
    case fd_executable() do
      fd when is_binary(fd) -> :fd
      nil -> detect_find_strategy()
    end
  end

  @spec detect_find_strategy() :: strategy()
  defp detect_find_strategy do
    if executable_available?("find"), do: :find, else: :none
  end

  @spec excludes() :: [String.t()]
  defp excludes, do: Minga.Config.get(:file_find_excludes)

  @spec filter_excludes([String.t()]) :: [String.t()]
  defp filter_excludes(paths) do
    excluded = MapSet.new(excludes())

    Enum.reject(paths, fn path ->
      path
      |> Path.split()
      |> Enum.any?(&MapSet.member?(excluded, &1))
    end)
  end

  @spec parse_lines(String.t()) :: [String.t()]
  defp parse_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&normalize_path/1)
    |> Enum.sort()
  end

  @spec normalize_path(String.t()) :: String.t()
  defp normalize_path("./" <> rest), do: rest
  defp normalize_path(path), do: path

  @spec executable_available?(String.t()) :: boolean()
  defp executable_available?(name), do: System.find_executable(name) != nil

  @spec fd_executable() :: String.t() | nil
  defp fd_executable, do: System.find_executable("fd") || System.find_executable("fdfind")

  @spec git_strategy_available?(String.t()) :: boolean()
  defp git_strategy_available?(root) do
    executable_available?("git") and git_repo_root?(root)
  end

  @spec git_repo_root?(String.t()) :: boolean()
  defp git_repo_root?(root), do: File.exists?(Path.join(root, ".git"))

  @spec root_error(Root.error(), String.t()) :: String.t()
  defp root_error(:not_a_directory, path), do: "Directory not found: #{path}"

  defp root_error(:broad_root_confirmation_required, path),
    do: "Broad project root requires explicit confirmation: #{path}"

  defp root_error(:not_a_directory_root, _path),
    do: "Project inventory requires an explicit directory workspace root"

  defp root_error(:invalid_broad_root_confirmation, path),
    do: "Broad project root confirmation must be true or false: #{path}"

  defp root_error(:root_changed, path),
    do: "Project root changed after authorization: #{path}"
end
