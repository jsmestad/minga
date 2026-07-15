defmodule Minga.Extension.SourceSnapshot do
  @moduledoc """
  Immutable, private snapshot of extension source selected for one compile attempt.

  Source count and byte limits are enforced while copying verified regular-file
  descriptors. The fingerprint and compiler paths are both derived from this
  snapshot, so cache selection and compilation cannot observe different bytes.
  """

  alias Minga.Extension.SecureFile

  @default_max_files 128
  @default_max_file_bytes 2 * 1024 * 1024
  @default_max_total_bytes 16 * 1024 * 1024

  @enforce_keys [:dir, :files, :fingerprint]
  defstruct [:dir, :files, :fingerprint]

  @type t :: %__MODULE__{dir: String.t(), files: [String.t()], fingerprint: binary()}

  @type error ::
          {:source_file_limit_exceeded, non_neg_integer(), pos_integer()}
          | {:source_total_bytes_exceeded, non_neg_integer(), pos_integer()}
          | {:source_outside_root, String.t()}
          | {:source_snapshot_failed, term()}
          | SecureFile.read_error()

  @doc "Snapshots the exact regular source files used by hashing and compilation."
  @spec create(String.t(), [String.t()], keyword()) :: {:ok, t()} | {:error, error()}
  def create(root, files, opts \\ []) when is_binary(root) and is_list(files) do
    max_files = limit(opts, :max_source_files, @default_max_files)
    max_file_bytes = limit(opts, :max_source_file_bytes, @default_max_file_bytes)
    max_total_bytes = limit(opts, :max_source_total_bytes, @default_max_total_bytes)

    with :ok <- validate_count(files, max_files),
         {:ok, dir} <- make_private_dir(opts),
         {:ok, copied, payload} <-
           copy_files(Path.expand(root), Enum.sort(files), dir, max_file_bytes, max_total_bytes) do
      fingerprint = :crypto.hash(:sha256, [version_tag(), 0, payload])
      {:ok, %__MODULE__{dir: dir, files: copied, fingerprint: fingerprint}}
    else
      {:error, _reason} = error -> error
    end
  end

  @doc "Removes a private source snapshot."
  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{dir: dir}) do
    File.rm_rf(dir)
    :ok
  end

  @spec validate_count([String.t()], pos_integer()) :: :ok | {:error, error()}
  defp validate_count(files, max_files) do
    count = length(files)

    if count <= max_files,
      do: :ok,
      else: {:error, {:source_file_limit_exceeded, count, max_files}}
  end

  @spec make_private_dir(keyword()) :: {:ok, String.t()} | {:error, error()}
  defp make_private_dir(opts) do
    parent = Keyword.get(opts, :snapshot_root, System.tmp_dir!())
    dir = Path.join(parent, "minga-extension-source-#{unique_suffix()}")

    case File.mkdir(dir) do
      :ok ->
        case File.chmod(dir, 0o700) do
          :ok ->
            {:ok, dir}

          {:error, reason} ->
            File.rm_rf(dir)
            {:error, {:source_snapshot_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:source_snapshot_failed, reason}}
    end
  end

  @spec copy_files(String.t(), [String.t()], String.t(), pos_integer(), pos_integer()) ::
          {:ok, [String.t()], iodata()} | {:error, error()}
  defp copy_files(root, files, dir, max_file_bytes, max_total_bytes) do
    files
    |> Enum.reduce_while({:ok, [], [], 0}, fn file, {:ok, copied, payload, total} ->
      with {:ok, relative} <- safe_relative(root, file),
           {:ok, binary} <- SecureFile.read(file, max_file_bytes),
           :ok <- validate_total(total + byte_size(binary), max_total_bytes),
           {:ok, destination} <- write_snapshot_file(dir, relative, binary) do
        next_payload = [payload, relative, 0, binary, 0]
        {:cont, {:ok, [destination | copied], next_payload, total + byte_size(binary)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, copied, payload, _total} ->
        {:ok, Enum.reverse(copied), payload}

      {:error, _reason} = error ->
        File.rm_rf(dir)
        error
    end
  end

  @spec safe_relative(String.t(), String.t()) :: {:ok, String.t()} | {:error, error()}
  defp safe_relative(root, file) do
    expanded = Path.expand(file)
    relative = Path.relative_to(expanded, root)

    if relative != "." and relative != ".." and not String.starts_with?(relative, "../") and
         Path.type(relative) != :absolute do
      {:ok, relative}
    else
      {:error, {:source_outside_root, file}}
    end
  end

  @spec validate_total(non_neg_integer(), pos_integer()) :: :ok | {:error, error()}
  defp validate_total(total, max) when total <= max, do: :ok
  defp validate_total(total, max), do: {:error, {:source_total_bytes_exceeded, total, max}}

  @spec write_snapshot_file(String.t(), String.t(), binary()) ::
          {:ok, String.t()} | {:error, error()}
  defp write_snapshot_file(dir, relative, binary) do
    destination = Path.join(dir, relative)

    with :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.write(destination, binary, [:binary, :exclusive]),
         :ok <- File.chmod(destination, 0o600) do
      {:ok, destination}
    else
      {:error, reason} -> {:error, {:source_snapshot_failed, {relative, reason}}}
    end
  end

  @spec limit(keyword(), atom(), pos_integer()) :: pos_integer()
  defp limit(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end

  @spec unique_suffix() :: String.t()
  defp unique_suffix do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @spec version_tag() :: String.t()
  defp version_tag do
    minga_vsn = to_string(Application.spec(:minga, :vsn) || "0")

    "artifact-v2-minga-#{minga_vsn}-elixir-#{System.version()}-erts-#{:erlang.system_info(:version)}"
  end
end
