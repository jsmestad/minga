defmodule Minga.Extension.ArtifactInventory do
  @moduledoc """
  Validates the complete BEAM output of an isolated extension compilation.

  Validation is deliberately performed before ownership or code-server
  mutation. The validator bounds artifact count, artifact bytes, and BEAM atom
  tables before `:beam_lib` is allowed to materialize any atoms in the host VM.
  Cache inventories include deterministic digests so missing, additional, or
  replaced files are rejected exactly like fresh compiler output.
  """

  import Bitwise

  alias Minga.Extension.Artifact
  alias Minga.Extension.ArtifactValidator
  alias Minga.Extension.EtfScanner

  @manifest_filename "inventory.etf"
  @manifest_version 1
  @default_max_artifacts 128
  @default_max_artifact_bytes 16 * 1024 * 1024
  @default_max_total_bytes 64 * 1024 * 1024
  @default_max_atoms_per_artifact 4_096
  @default_max_total_atoms 16_384
  @default_max_atom_name_bytes 255
  @default_host_atom_reserve 65_536
  @default_max_manifest_bytes 1_048_576
  @default_max_decompressed_bytes 32 * 1024 * 1024
  @default_max_total_decompressed_bytes 128 * 1024 * 1024

  @enforce_keys [:artifacts, :fingerprint]
  defstruct [:artifacts, :fingerprint, :snapshot_dir]

  @type t :: %__MODULE__{
          artifacts: [Artifact.t()],
          fingerprint: binary(),
          snapshot_dir: String.t() | nil
        }

  @type validation_error ::
          :empty_inventory
          | {:artifact_limit_exceeded, non_neg_integer(), pos_integer()}
          | {:unexpected_artifact_entry, String.t()}
          | {:non_regular_artifact_entry, String.t(), atom()}
          | {:non_regular_cache_directory, String.t(), atom()}
          | {:artifact_read_failed, String.t(), File.posix()}
          | {:artifact_too_large, String.t(), non_neg_integer(), pos_integer()}
          | {:total_artifact_bytes_exceeded, non_neg_integer(), pos_integer()}
          | {:invalid_beam, String.t(), term()}
          | {:atom_limit_exceeded, String.t(), non_neg_integer(), pos_integer()}
          | {:total_atom_limit_exceeded, non_neg_integer(), pos_integer()}
          | {:host_atom_capacity_exceeded, non_neg_integer(), non_neg_integer(), pos_integer(),
             pos_integer()}
          | {:invalid_atom_name, String.t(), term()}
          | {:invalid_module_name, String.t()}
          | {:filename_module_mismatch, String.t(), String.t()}
          | {:duplicate_module_identity, String.t()}
          | {:incomplete_compiler_output, [String.t()], [String.t()]}
          | {:cache_manifest_missing, String.t()}
          | {:cache_manifest_invalid, term()}
          | {:cache_manifest_mismatch, term()}

  @doc "Returns the cache manifest filename reserved by the inventory contract."
  @spec manifest_filename() :: String.t()
  def manifest_filename, do: @manifest_filename

  @doc "Validates fresh compiler output and verifies the compiler's complete module report."
  @spec validate_staging(String.t(), [String.t()], keyword()) ::
          {:ok, t()} | {:error, validation_error()}
  def validate_staging(dir, expected_modules, opts \\ [])
      when is_binary(dir) and is_list(expected_modules) do
    ArtifactValidator.validate(dir, {:staging, expected_modules}, opts)
  end

  @doc "Validates a cache directory and its deterministic completeness manifest."
  @spec validate_cache(String.t(), keyword()) ::
          :miss | {:ok, t()} | {:error, validation_error()}
  def validate_cache(dir, opts \\ []) when is_binary(dir) do
    ArtifactValidator.validate(dir, :cache, opts)
  end

  @doc false
  @spec validate_in_disposable(String.t(), ArtifactValidator.mode(), keyword()) ::
          {:ok, t()} | {:error, validation_error()}
  def validate_in_disposable(dir, {:staging, expected_modules}, opts) do
    with {:ok, inventory} <- validate_directory(dir, false, opts),
         :ok <- validate_expected_modules(inventory, expected_modules) do
      {:ok, inventory}
    end
  end

  def validate_in_disposable(dir, :cache, opts) do
    with {:ok, inventory} <- validate_directory(dir, true, opts),
         {:ok, manifest} <- read_manifest(dir, opts),
         :ok <- validate_manifest(inventory, manifest, opts) do
      {:ok, inventory}
    end
  end

  @doc "Writes the deterministic completeness manifest after fresh validation."
  @spec write_manifest(String.t(), t(), keyword()) :: :ok | {:error, term()}
  def write_manifest(dir, %__MODULE__{} = inventory, opts \\ []) do
    manifest = %{
      version: @manifest_version,
      fingerprint: inventory.fingerprint,
      artifacts:
        Enum.map(inventory.artifacts, fn artifact ->
          {artifact.filename, artifact.module_name, artifact.digest}
        end)
    }

    encoded = %{
      "version" => manifest.version,
      "fingerprint" => Base.encode64(manifest.fingerprint),
      "artifacts" =>
        Enum.map(manifest.artifacts, fn {filename, module_name, digest} ->
          [filename, module_name, Base.encode64(digest)]
        end)
    }

    binary = JSON.encode!(encoded)
    max_bytes = limit(opts, :max_manifest_bytes, @default_max_manifest_bytes)

    if byte_size(binary) <= max_bytes do
      File.write(Path.join(dir, @manifest_filename), binary, [:binary, :exclusive])
    else
      {:error, {:cache_manifest_invalid, {:too_large, byte_size(binary), max_bytes}}}
    end
  end

  @doc "Rebases validated artifact paths after an atomic staging-directory rename."
  @spec rebase(t(), String.t()) :: t()
  def rebase(%__MODULE__{} = inventory, dir) when is_binary(dir) do
    artifacts =
      Enum.map(inventory.artifacts, fn %Artifact{} = artifact ->
        %Artifact{artifact | path: Path.join(dir, artifact.filename)}
      end)

    %__MODULE__{inventory | artifacts: artifacts, snapshot_dir: dir}
  end

  @doc "Removes an inventory's private validation snapshot after admission finishes."
  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{snapshot_dir: nil}), do: :ok

  def cleanup(%__MODULE__{snapshot_dir: dir}) do
    File.rm_rf(dir)
    :ok
  end

  @spec validate_directory(String.t(), boolean(), keyword()) ::
          {:ok, t()} | {:error, validation_error()}
  defp validate_directory(dir, allow_manifest?, opts) do
    with :ok <- validate_directory_type(dir),
         {:ok, entries} <- list_entries(dir),
         {:ok, beam_entries} <- validate_entries(entries, allow_manifest?),
         :ok <-
           validate_artifact_count(
             beam_entries,
             limit(opts, :max_artifacts, @default_max_artifacts)
           ),
         {:ok, artifacts} <- validate_beams(dir, beam_entries, opts),
         :ok <- validate_unique_modules(artifacts) do
      artifacts = Enum.sort_by(artifacts, & &1.module_name)
      {:ok, %__MODULE__{artifacts: artifacts, fingerprint: fingerprint(artifacts)}}
    end
  end

  @spec validate_directory_type(String.t()) :: :ok | {:error, validation_error()}
  defp validate_directory_type(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:non_regular_cache_directory, dir, type}}
      {:error, reason} -> {:error, {:artifact_read_failed, dir, reason}}
    end
  end

  @spec list_entries(String.t()) :: {:ok, [String.t()]} | {:error, validation_error()}
  defp list_entries(dir) do
    case File.ls(dir) do
      {:ok, entries} -> {:ok, Enum.sort(entries)}
      {:error, reason} -> {:error, {:artifact_read_failed, dir, reason}}
    end
  end

  @spec validate_entries([String.t()], boolean()) ::
          {:ok, [String.t()]} | {:error, validation_error()}
  defp validate_entries(entries, allow_manifest?) do
    allowed_manifest = if allow_manifest?, do: [@manifest_filename], else: []
    beams = Enum.filter(entries, &String.ends_with?(&1, ".beam"))
    unexpected = entries -- (beams ++ allowed_manifest)

    case unexpected do
      [] -> {:ok, beams}
      [entry | _rest] -> {:error, {:unexpected_artifact_entry, entry}}
    end
  end

  @spec validate_artifact_count([String.t()], pos_integer()) ::
          :ok | {:error, validation_error()}
  defp validate_artifact_count([], _max), do: {:error, :empty_inventory}

  defp validate_artifact_count(entries, max) do
    count = length(entries)
    if count <= max, do: :ok, else: {:error, {:artifact_limit_exceeded, count, max}}
  end

  @typep preflight_artifact :: %{
           module_name: String.t(),
           filename: String.t(),
           path: String.t(),
           bytecode: binary(),
           digest: binary(),
           byte_size: non_neg_integer(),
           atom_count: non_neg_integer(),
           decompressed_bytes: non_neg_integer()
         }

  @spec validate_beams(String.t(), [String.t()], keyword()) ::
          {:ok, [Artifact.t()]} | {:error, validation_error()}
  defp validate_beams(dir, entries, opts) do
    limits = %{
      artifact_bytes: limit(opts, :max_artifact_bytes, @default_max_artifact_bytes),
      total_bytes: limit(opts, :max_total_bytes, @default_max_total_bytes),
      artifact_atoms: limit(opts, :max_atoms_per_artifact, @default_max_atoms_per_artifact),
      total_atoms: limit(opts, :max_total_atoms, @default_max_total_atoms),
      atom_name_bytes: limit(opts, :max_atom_name_bytes, @default_max_atom_name_bytes),
      host_atom_reserve: limit(opts, :host_atom_reserve, @default_host_atom_reserve),
      decompressed_bytes: limit(opts, :max_decompressed_bytes, @default_max_decompressed_bytes),
      total_decompressed_bytes:
        limit(opts, :max_total_decompressed_bytes, @default_max_total_decompressed_bytes)
    }

    with {:ok, preflight, total_bytes, total_atoms, total_decompressed} <-
           preflight_beams(dir, entries, limits),
         :ok <- validate_totals(total_bytes, total_atoms, total_decompressed, limits),
         :ok <- validate_host_atom_capacity(total_atoms, limits.host_atom_reserve) do
      materialize_artifacts(preflight)
    end
  end

  @spec preflight_beams(String.t(), [String.t()], map()) ::
          {:ok, [preflight_artifact()], non_neg_integer(), non_neg_integer(), non_neg_integer()}
          | {:error, validation_error()}
  defp preflight_beams(dir, entries, limits) do
    entries
    |> Enum.reduce_while({:ok, [], 0, 0, 0}, fn filename, state ->
      dir
      |> preflight_beam(filename, limits)
      |> accumulate_preflight(state, limits)
    end)
    |> case do
      {:ok, artifacts, bytes, atoms, decompressed} ->
        {:ok, Enum.reverse(artifacts), bytes, atoms, decompressed}

      {:error, _reason} = error ->
        error
    end
  end

  @spec accumulate_preflight(
          {:ok, preflight_artifact()} | {:error, validation_error()},
          {:ok, [preflight_artifact()], non_neg_integer(), non_neg_integer(), non_neg_integer()},
          map()
        ) ::
          {:cont,
           {:ok, [preflight_artifact()], non_neg_integer(), non_neg_integer(), non_neg_integer()}}
          | {:halt, {:error, validation_error()}}
  defp accumulate_preflight({:ok, artifact}, {:ok, acc, bytes, atoms, decompressed}, limits) do
    total_bytes = bytes + artifact.byte_size
    total_atoms = atoms + artifact.atom_count
    total_decompressed = decompressed + artifact.decompressed_bytes

    case validate_totals(total_bytes, total_atoms, total_decompressed, limits) do
      :ok ->
        {:cont, {:ok, [artifact | acc], total_bytes, total_atoms, total_decompressed}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp accumulate_preflight({:error, _reason} = error, _state, _limits),
    do: {:halt, error}

  @spec preflight_beam(String.t(), String.t(), map()) ::
          {:ok, preflight_artifact()} | {:error, validation_error()}
  defp preflight_beam(dir, filename, limits) do
    path = Path.join(dir, filename)

    with {:ok, binary} <- read_regular_file(path, filename),
         :ok <- validate_artifact_size(filename, byte_size(binary), limits.artifact_bytes),
         {:ok, module_name, atom_count, decompressed_bytes} <-
           preflight_atom_table(binary, filename, limits),
         :ok <- validate_module_name(module_name),
         :ok <- validate_filename(filename, module_name) do
      {:ok,
       %{
         module_name: module_name,
         filename: filename,
         path: path,
         bytecode: binary,
         digest: :crypto.hash(:sha256, binary),
         byte_size: byte_size(binary),
         atom_count: atom_count,
         decompressed_bytes: decompressed_bytes
       }}
    end
  end

  @spec read_regular_file(String.t(), String.t()) ::
          {:ok, binary()} | {:error, validation_error()}
  defp read_regular_file(path, display_name) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(path) do
          {:ok, binary} -> {:ok, binary}
          {:error, reason} -> {:error, {:artifact_read_failed, display_name, reason}}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, {:non_regular_artifact_entry, display_name, type}}

      {:error, reason} ->
        {:error, {:artifact_read_failed, display_name, reason}}
    end
  end

  @spec materialize_artifacts([preflight_artifact()]) ::
          {:ok, [Artifact.t()]} | {:error, validation_error()}
  defp materialize_artifacts(preflight) do
    Enum.reduce_while(preflight, {:ok, []}, fn candidate, {:ok, artifacts} ->
      case beam_module(candidate.bytecode, candidate.filename, candidate.module_name) do
        {:ok, module} ->
          fields = candidate |> Map.delete(:decompressed_bytes) |> Map.put(:module, module)
          artifact = struct!(Artifact, fields)
          {:cont, {:ok, [artifact | artifacts]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      {:error, _reason} = error -> error
    end
  end

  @spec validate_artifact_size(String.t(), non_neg_integer(), pos_integer()) ::
          :ok | {:error, validation_error()}
  defp validate_artifact_size(filename, size, max) do
    if size <= max, do: :ok, else: {:error, {:artifact_too_large, filename, size, max}}
  end

  @spec validate_totals(non_neg_integer(), non_neg_integer(), non_neg_integer(), map()) ::
          :ok | {:error, validation_error()}
  defp validate_totals(bytes, _atoms, _decompressed, %{total_bytes: max}) when bytes > max,
    do: {:error, {:total_artifact_bytes_exceeded, bytes, max}}

  defp validate_totals(_bytes, atoms, _decompressed, %{total_atoms: max}) when atoms > max,
    do: {:error, {:total_atom_limit_exceeded, atoms, max}}

  defp validate_totals(_bytes, _atoms, decompressed, %{total_decompressed_bytes: max})
       when decompressed > max,
       do:
         {:error,
          {:invalid_beam, "decompressed", {:decompressed_limit_exceeded, decompressed, max}}}

  defp validate_totals(_bytes, _atoms, _decompressed, _limits), do: :ok

  @spec validate_host_atom_capacity(non_neg_integer(), pos_integer()) ::
          :ok | {:error, validation_error()}
  defp validate_host_atom_capacity(inventory_atoms, reserve) do
    current = :erlang.system_info(:atom_count)
    atom_limit = :erlang.system_info(:atom_limit)

    if current + inventory_atoms + reserve <= atom_limit do
      :ok
    else
      {:error, {:host_atom_capacity_exceeded, current, inventory_atoms, reserve, atom_limit}}
    end
  end

  @spec preflight_atom_table(binary(), String.t(), map()) ::
          {:ok, String.t(), non_neg_integer(), non_neg_integer()} | {:error, validation_error()}
  defp preflight_atom_table(binary, filename, limits) do
    with {:ok, chunks} <- beam_chunks(binary),
         {:ok, encoding, atom_chunk} <- atom_chunk(chunks),
         {:ok, declared_count} <- atom_table_count(atom_chunk),
         :ok <- validate_declared_atom_count(filename, declared_count, limits.artifact_atoms),
         {:ok, atoms} <- decode_atom_table(atom_chunk, encoding),
         :ok <- validate_atom_table(filename, atoms, limits),
         {:ok, etf_atoms, decompressed_bytes} <-
           scan_etf_chunks(chunks, length(atoms), limits),
         total_atoms = length(atoms) + etf_atoms,
         :ok <- validate_declared_atom_count(filename, total_atoms, limits.artifact_atoms) do
      case atoms do
        [module_name | _rest] -> {:ok, module_name, total_atoms, decompressed_bytes}
        [] -> {:error, {:invalid_beam, filename, :empty_atom_table}}
      end
    else
      {:error, {:atom_limit_exceeded, _filename, _count, _max}} = error ->
        error

      {:error, {:invalid_atom_name, _filename, _reason}} = error ->
        error

      {:error, {:etf_atom_limit_exceeded, count, max}} ->
        {:error, {:atom_limit_exceeded, filename, count, max}}

      {:error, reason} ->
        {:error, {:invalid_beam, filename, reason}}
    end
  end

  @spec atom_table_count(binary()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp atom_table_count(<<signed_count::signed-big-32, _rest::binary>>) when signed_count < 0,
    do: {:ok, -signed_count}

  defp atom_table_count(<<count::unsigned-big-32, _rest::binary>>), do: {:ok, count}
  defp atom_table_count(_chunk), do: {:error, :truncated_atom_table}

  @spec validate_declared_atom_count(String.t(), non_neg_integer(), pos_integer()) ::
          :ok | {:error, validation_error()}
  defp validate_declared_atom_count(filename, count, max) when count > max,
    do: {:error, {:atom_limit_exceeded, filename, count, max}}

  defp validate_declared_atom_count(_filename, _count, _max), do: :ok

  @spec beam_chunks(binary()) :: {:ok, [{binary(), binary()}]} | {:error, term()}
  defp beam_chunks(<<"FOR1", declared::unsigned-big-32, "BEAM", rest::binary>>)
       when declared == byte_size(rest) + 4 do
    decode_chunks(rest, [])
  end

  defp beam_chunks(_binary), do: {:error, :invalid_container}

  @spec decode_chunks(binary(), [{binary(), binary()}]) ::
          {:ok, [{binary(), binary()}]} | {:error, term()}
  defp decode_chunks(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_chunks(<<id::binary-size(4), size::unsigned-big-32, rest::binary>>, acc)
       when byte_size(rest) >= size do
    padding = rem(4 - rem(size, 4), 4)

    if byte_size(rest) >= size + padding do
      <<chunk::binary-size(^size), _padding::binary-size(^padding), tail::binary>> = rest
      decode_chunks(tail, [{id, chunk} | acc])
    else
      {:error, :truncated_chunk_padding}
    end
  end

  defp decode_chunks(_rest, _acc), do: {:error, :truncated_chunk}

  @spec scan_etf_chunks([{binary(), binary()}], non_neg_integer(), map()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, term()}
  defp scan_etf_chunks(chunks, beam_atoms, limits) do
    attrs = for {"Attr", data} <- chunks, do: {:attr, data}
    literals = for {"LitT", data} <- chunks, do: {:literals, data}

    case {attrs, literals} do
      {[_first, _second | _rest], _literals} ->
        {:error, :duplicate_etf_chunk}

      {_attrs, [_first, _second | _rest]} ->
        {:error, :duplicate_etf_chunk}

      {attrs, literals} ->
        scan_etf_payloads(attrs ++ literals, beam_atoms, limits)
    end
  end

  @spec scan_etf_payloads([{:attr | :literals, binary()}], non_neg_integer(), map()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, term()}
  defp scan_etf_payloads(payloads, beam_atoms, limits) do
    Enum.reduce_while(payloads, {:ok, 0, 0}, fn {kind, payload}, {:ok, atoms, decompressed} ->
      scanner_limits = %{
        max_atoms: limits.artifact_atoms - beam_atoms - atoms,
        max_atom_name_bytes: limits.atom_name_bytes,
        max_decompressed_bytes: limits.decompressed_bytes - decompressed
      }

      result =
        case kind do
          :attr -> EtfScanner.scan_external(payload, scanner_limits)
          :literals -> EtfScanner.scan_literal_table(payload, scanner_limits)
        end

      case result do
        {:ok, scanned} ->
          {:cont, {:ok, atoms + scanned.atom_count, decompressed + scanned.decompressed_bytes}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  @spec atom_chunk([{binary(), binary()}]) ::
          {:ok, :utf8 | :latin1, binary()} | {:error, term()}
  defp atom_chunk(chunks) do
    utf8 = for {"AtU8", data} <- chunks, do: data
    latin1 = for {"Atom", data} <- chunks, do: data

    case {utf8, latin1} do
      {[data], []} -> {:ok, :utf8, data}
      {[], [data]} -> {:ok, :latin1, data}
      {[], []} -> {:error, :missing_atom_table}
      _other -> {:error, :duplicate_atom_table}
    end
  end

  @spec decode_atom_table(binary(), :utf8 | :latin1) ::
          {:ok, [String.t()]} | {:error, term()}
  defp decode_atom_table(<<signed_count::signed-big-32, rest::binary>>, encoding)
       when signed_count < 0 do
    decode_atoms(rest, -signed_count, encoding, :compact, [])
  end

  defp decode_atom_table(<<count::unsigned-big-32, rest::binary>>, encoding) do
    decode_atoms(rest, count, encoding, :byte, [])
  end

  defp decode_atom_table(_chunk, _encoding), do: {:error, :truncated_atom_table}

  @spec decode_atoms(
          binary(),
          non_neg_integer(),
          :utf8 | :latin1,
          :compact | :byte,
          [String.t()]
        ) :: {:ok, [String.t()]} | {:error, term()}
  defp decode_atoms(<<>>, 0, _encoding, _length_mode, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_atoms(_trailing, 0, _encoding, _length_mode, _acc),
    do: {:error, :atom_table_trailing_bytes}

  defp decode_atoms(rest, remaining, encoding, length_mode, acc) when remaining > 0 do
    with {:ok, size, after_length} <- decode_atom_length(rest, length_mode),
         true <- byte_size(after_length) >= size do
      <<name::binary-size(^size), tail::binary>> = after_length

      case normalize_atom_name(name, encoding) do
        {:ok, normalized} ->
          decode_atoms(tail, remaining - 1, encoding, length_mode, [normalized | acc])

        {:error, _reason} = error ->
          error
      end
    else
      false -> {:error, :truncated_atom_name}
      {:error, _reason} = error -> error
    end
  end

  @spec decode_atom_length(binary(), :compact | :byte) ::
          {:ok, non_neg_integer(), binary()} | {:error, term()}
  defp decode_atom_length(<<size, rest::binary>>, :byte), do: {:ok, size, rest}

  defp decode_atom_length(<<first, rest::binary>>, :compact) when (first &&& 0x07) == 0 do
    decode_compact_unsigned(first, rest)
  end

  defp decode_atom_length(_binary, _mode), do: {:error, :invalid_atom_length}

  @spec decode_compact_unsigned(non_neg_integer(), binary()) ::
          {:ok, non_neg_integer(), binary()} | {:error, term()}
  defp decode_compact_unsigned(first, rest) when (first &&& 0x08) == 0,
    do: {:ok, first >>> 4, rest}

  defp decode_compact_unsigned(first, <<second, rest::binary>>)
       when (first &&& 0x18) == 0x08 do
    {:ok, (first &&& 0xE0) <<< 3 ||| second, rest}
  end

  defp decode_compact_unsigned(first, rest)
       when (first &&& 0x18) == 0x18 and (first &&& 0xE0) != 0xE0 do
    byte_count = (first >>> 5) + 2
    decode_big_unsigned(rest, byte_count)
  end

  defp decode_compact_unsigned(0xF8, rest) do
    with {:ok, extra_bytes, after_size} <- decode_atom_length(rest, :compact) do
      decode_big_unsigned(after_size, extra_bytes + 9)
    end
  end

  defp decode_compact_unsigned(_first, _rest), do: {:error, :invalid_compact_atom_length}

  @spec decode_big_unsigned(binary(), pos_integer()) ::
          {:ok, non_neg_integer(), binary()} | {:error, term()}
  defp decode_big_unsigned(binary, byte_count) when byte_size(binary) >= byte_count do
    <<encoded::binary-size(^byte_count), rest::binary>> = binary
    {:ok, :binary.decode_unsigned(encoded), rest}
  end

  defp decode_big_unsigned(_binary, _byte_count), do: {:error, :truncated_compact_atom_length}

  @spec normalize_atom_name(binary(), :utf8 | :latin1) :: {:ok, String.t()} | {:error, term()}
  defp normalize_atom_name(name, :utf8) do
    if String.valid?(name), do: {:ok, name}, else: {:error, :invalid_utf8_atom}
  end

  defp normalize_atom_name(name, :latin1), do: {:ok, :unicode.characters_to_binary(name, :latin1)}

  @spec validate_atom_table(String.t(), [String.t()], map()) ::
          :ok | {:error, validation_error()}
  defp validate_atom_table(filename, atoms, limits) do
    count = length(atoms)

    if count > limits.artifact_atoms do
      {:error, {:atom_limit_exceeded, filename, count, limits.artifact_atoms}}
    else
      validate_atom_names(filename, atoms, limits.atom_name_bytes)
    end
  end

  @spec validate_atom_names(String.t(), [String.t()], pos_integer()) ::
          :ok | {:error, validation_error()}
  defp validate_atom_names(filename, atoms, max) do
    case Enum.find(atoms, &(byte_size(&1) == 0 or byte_size(&1) > max)) do
      nil -> :ok
      name -> {:error, {:invalid_atom_name, filename, byte_size(name)}}
    end
  end

  @spec validate_module_name(String.t()) :: :ok | {:error, validation_error()}
  defp validate_module_name("Elixir." <> rest = module_name) do
    segments = String.split(rest, ".")

    if segments != [] and Enum.all?(segments, &Regex.match?(~r/^[A-Z][A-Za-z0-9_]*$/, &1)) do
      :ok
    else
      {:error, {:invalid_module_name, module_name}}
    end
  end

  defp validate_module_name(module_name), do: {:error, {:invalid_module_name, module_name}}

  @spec validate_filename(String.t(), String.t()) :: :ok | {:error, validation_error()}
  defp validate_filename(filename, module_name) do
    expected = module_name <> ".beam"

    if filename == expected,
      do: :ok,
      else: {:error, {:filename_module_mismatch, filename, module_name}}
  end

  @spec beam_module(binary(), String.t(), String.t()) ::
          {:ok, module()} | {:error, validation_error()}
  defp beam_module(binary, filename, expected_name) do
    owner = self()
    ref = make_ref()
    max_words = div(@default_max_decompressed_bytes * 2, :erlang.system_info(:wordsize))

    {pid, monitor} =
      :erlang.spawn_opt(
        fn -> send(owner, {ref, decode_beam_module(binary, filename, expected_name)}) end,
        [:monitor, {:max_heap_size, %{size: max_words, kill: true, error_logger: false}}]
      )

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, {:invalid_beam, filename, :semantic_validation_memory_limit}}
    after
      5_000 ->
        Process.exit(pid, :kill)
        {:error, {:invalid_beam, filename, :semantic_validation_timeout}}
    end
  end

  @spec decode_beam_module(binary(), String.t(), String.t()) ::
          {:ok, module()} | {:error, validation_error()}
  defp decode_beam_module(binary, filename, expected_name) do
    case :beam_lib.chunks(binary, [:attributes]) do
      {:ok, {module, _chunks}} when is_atom(module) ->
        if Atom.to_string(module) == expected_name,
          do: {:ok, module},
          else: {:error, {:invalid_beam, filename, :metadata_identity_mismatch}}

      {:error, :beam_lib, reason} ->
        {:error, {:invalid_beam, filename, reason}}
    end
  rescue
    error -> {:error, {:invalid_beam, filename, Exception.message(error)}}
  end

  @spec validate_unique_modules([Artifact.t()]) :: :ok | {:error, validation_error()}
  defp validate_unique_modules(artifacts) do
    case artifacts
         |> Enum.frequencies_by(& &1.module_name)
         |> Enum.find(fn {_module, count} -> count > 1 end) do
      nil -> :ok
      {module_name, _count} -> {:error, {:duplicate_module_identity, module_name}}
    end
  end

  @spec validate_expected_modules(t(), [String.t()]) :: :ok | {:error, validation_error()}
  defp validate_expected_modules(%__MODULE__{} = inventory, expected_modules) do
    actual = Enum.map(inventory.artifacts, & &1.module_name) |> Enum.sort()
    expected = Enum.sort(Enum.uniq(expected_modules))

    if actual == expected do
      :ok
    else
      {:error, {:incomplete_compiler_output, expected -- actual, actual -- expected}}
    end
  end

  @spec read_manifest(String.t(), keyword()) :: {:ok, map()} | {:error, validation_error()}
  defp read_manifest(dir, opts) do
    path = Path.join(dir, @manifest_filename)
    max_bytes = limit(opts, :max_manifest_bytes, @default_max_manifest_bytes)

    case read_regular_file(path, @manifest_filename) do
      {:ok, binary} when byte_size(binary) <= max_bytes ->
        decode_manifest(binary)

      {:ok, binary} ->
        {:error, {:cache_manifest_invalid, {:too_large, byte_size(binary), max_bytes}}}

      {:error, {:artifact_read_failed, _path, :enoent}} ->
        {:error, {:cache_manifest_missing, path}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec decode_manifest(binary()) :: {:ok, map()} | {:error, validation_error()}
  defp decode_manifest(binary) do
    with {:ok,
          %{
            "version" => @manifest_version,
            "fingerprint" => encoded_fingerprint,
            "artifacts" => encoded_artifacts
          }} <- JSON.decode(binary),
         {:ok, fingerprint} <- decode_manifest_digest(encoded_fingerprint),
         {:ok, artifacts} <- decode_manifest_artifacts(encoded_artifacts) do
      {:ok, %{version: @manifest_version, fingerprint: fingerprint, artifacts: artifacts}}
    else
      {:error, reason} -> {:error, {:cache_manifest_invalid, reason}}
      _other -> {:error, {:cache_manifest_invalid, :invalid_shape}}
    end
  end

  @spec decode_manifest_artifacts(term()) :: {:ok, [tuple()]} | {:error, term()}
  defp decode_manifest_artifacts(artifacts) when is_list(artifacts) do
    Enum.reduce_while(artifacts, {:ok, []}, fn
      [filename, module_name, encoded_digest], {:ok, acc}
      when is_binary(filename) and is_binary(module_name) and is_binary(encoded_digest) ->
        case decode_manifest_digest(encoded_digest) do
          {:ok, digest} -> {:cont, {:ok, [{filename, module_name, digest} | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end

      _artifact, _acc ->
        {:halt, {:error, :invalid_artifact}}
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_manifest_artifacts(_artifacts), do: {:error, :invalid_artifacts}

  @spec decode_manifest_digest(term()) :: {:ok, binary()} | {:error, term()}
  defp decode_manifest_digest(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, digest} when byte_size(digest) == 32 -> {:ok, digest}
      _other -> {:error, :invalid_digest}
    end
  end

  defp decode_manifest_digest(_encoded), do: {:error, :invalid_digest}

  @spec validate_manifest(t(), map(), keyword()) :: :ok | {:error, validation_error()}
  defp validate_manifest(%__MODULE__{} = inventory, manifest, opts) do
    actual =
      Enum.map(inventory.artifacts, fn artifact ->
        {artifact.filename, artifact.module_name, artifact.digest}
      end)

    expected = manifest.artifacts
    max_artifacts = limit(opts, :max_artifacts, @default_max_artifacts)

    if valid_manifest_artifacts?(expected, max_artifacts) and
         manifest.fingerprint == inventory.fingerprint and expected == actual do
      :ok
    else
      {:error, {:cache_manifest_mismatch, %{expected: expected, actual: actual}}}
    end
  end

  @spec valid_manifest_artifacts?([term()], pos_integer()) :: boolean()
  defp valid_manifest_artifacts?(artifacts, max) when is_list(artifacts) do
    length(artifacts) <= max and
      Enum.all?(artifacts, fn
        {filename, module_name, digest}
        when is_binary(filename) and is_binary(module_name) and is_binary(digest) ->
          byte_size(filename) <= 262 and byte_size(module_name) <= 255 and byte_size(digest) == 32

        _other ->
          false
      end)
  end

  @spec fingerprint([Artifact.t()]) :: binary()
  defp fingerprint(artifacts) do
    payload =
      Enum.map(artifacts, fn artifact ->
        [artifact.module_name, 0, artifact.digest, 0]
      end)

    :crypto.hash(:sha256, payload)
  end

  @spec limit(keyword(), atom(), pos_integer()) :: pos_integer()
  defp limit(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end
end
