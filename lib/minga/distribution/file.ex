defmodule Minga.Distribution.File do
  @moduledoc "Remote file helpers for bounded read-only browsing over Erlang distribution."

  @text_extensions ~w(.ex .exs .heex .eex .leex .json .yaml .yml .md .txt .zig .swift .js .ts .tsx .jsx .css .html .sh .zsh .toml .erl .hrl .c .h .cpp .hpp .rs .go .py .rb)
  @ignored_dirs ~w(.git deps _build node_modules .elixir_ls .zig-cache .build)
  @default_max_file_bytes 1_000_000
  @default_max_files 5_000
  @default_max_depth 12

  @type listing_acc :: %{files: [String.t()], truncated?: boolean()}
  @type listing_limits :: %{max_files: pos_integer(), max_depth: non_neg_integer()}

  @doc "Reads a file from a remote node. Files larger than the configured cap are rejected."
  @spec read(node(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read(node, path), do: read(node, path, [])

  @doc "Reads a file from a remote node with options."
  @spec read(node(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read(node, path, opts) when is_atom(node) and is_binary(path) and is_list(opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_file_bytes)
    :erpc.call(node, __MODULE__, :read_local, [path, max_bytes], 5_000)
  catch
    :exit, reason -> {:error, {:remote_unavailable, reason}}
  end

  @doc "Reads a local file for remote `:erpc.call/5` use."
  @spec read_local(String.t(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def read_local(path, max_bytes)
      when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, file} <- File.open(path, [:read, :binary]) do
      read_open_file(file, max_bytes)
    else
      {:ok, %File.Stat{}} -> {:error, :not_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Lists text files below `root` on a remote node. Results are bounded to protect both nodes."
  @spec list_files(node(), String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list_files(node, root, opts \\ [])
      when is_atom(node) and is_binary(root) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    max_files = Keyword.get(opts, :max_files, @default_max_files)
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    :erpc.call(node, __MODULE__, :list_local_files, [root, max_files, max_depth], timeout)
  catch
    :exit, reason -> {:error, {:remote_unavailable, reason}}
  end

  @doc "Lists text files below `root` on the current node. Intended for remote `:erpc.call/5` use."
  @spec list_local_files(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_local_files(root), do: list_local_files(root, @default_max_files, @default_max_depth)

  @doc "Lists text files below `root` with explicit limits. Intended for remote `:erpc.call/5` use."
  @spec list_local_files(String.t(), pos_integer(), non_neg_integer()) ::
          {:ok, [String.t()]} | {:error, term()}
  def list_local_files(root, max_files, max_depth)
      when is_binary(root) and is_integer(max_files) and max_files > 0 and is_integer(max_depth) and
             max_depth >= 0 do
    expanded = Path.expand(root)

    if File.dir?(expanded) do
      limits = %{max_files: max_files, max_depth: max_depth}
      acc = collect_files(expanded, 0, limits, %{files: [], truncated?: false})
      {:ok, Enum.sort(acc.files)}
    else
      {:error, :enoent}
    end
  end

  @spec read_open_file(File.io_device(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  defp read_open_file(file, max_bytes) do
    case IO.binread(file, max_bytes + 1) do
      data when is_binary(data) and byte_size(data) > max_bytes -> {:error, :file_too_large}
      data when is_binary(data) -> {:ok, data}
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  after
    File.close(file)
  end

  @spec collect_files(String.t(), non_neg_integer(), listing_limits(), listing_acc()) ::
          listing_acc()
  defp collect_files(dir, depth, limits, acc) do
    case File.ls(dir) do
      {:ok, entries} -> collect_entries(entries, dir, depth, limits, acc)
      {:error, _reason} -> acc
    end
  end

  @spec collect_entries(
          [String.t()],
          String.t(),
          non_neg_integer(),
          listing_limits(),
          listing_acc()
        ) :: listing_acc()
  defp collect_entries([], _dir, _depth, _limits, acc), do: acc
  defp collect_entries(_entries, _dir, _depth, _limits, %{truncated?: true} = acc), do: acc

  defp collect_entries([entry | rest], dir, depth, limits, acc) do
    path = Path.join(dir, entry)
    acc = collect_path(path, entry, depth, limits, acc)
    collect_entries(rest, dir, depth, limits, acc)
  end

  @spec collect_path(String.t(), String.t(), non_neg_integer(), listing_limits(), listing_acc()) ::
          listing_acc()
  defp collect_path(path, entry, depth, limits, acc) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> collect_directory(path, entry, depth, limits, acc)
      {:ok, %File.Stat{type: :regular}} -> collect_file(path, limits, acc)
      {:ok, %File.Stat{}} -> acc
      {:error, _reason} -> acc
    end
  end

  @spec collect_directory(
          String.t(),
          String.t(),
          non_neg_integer(),
          listing_limits(),
          listing_acc()
        ) :: listing_acc()
  defp collect_directory(_path, entry, _depth, _limits, acc) when entry in @ignored_dirs, do: acc

  defp collect_directory(_path, _entry, depth, %{max_depth: max_depth}, acc)
       when depth >= max_depth, do: acc

  defp collect_directory(path, _entry, depth, limits, acc),
    do: collect_files(path, depth + 1, limits, acc)

  @spec collect_file(String.t(), listing_limits(), listing_acc()) :: listing_acc()
  defp collect_file(path, limits, acc) do
    if Path.extname(path) in @text_extensions do
      add_file(path, limits, acc)
    else
      acc
    end
  end

  @spec add_file(String.t(), listing_limits(), listing_acc()) :: listing_acc()
  defp add_file(path, %{max_files: max_files}, acc) do
    if length(acc.files) >= max_files do
      %{acc | truncated?: true}
    else
      %{acc | files: [path | acc.files]}
    end
  end
end
