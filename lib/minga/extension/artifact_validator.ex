defmodule Minga.Extension.ArtifactValidator do
  @moduledoc false

  alias Minga.Extension.Artifact
  alias Minga.Extension.ArtifactInventory
  alias Minga.Extension.DisposableBeam
  alias Minga.Extension.SecureFile

  @default_timeout 30_000
  @max_report_bytes 256 * 1024
  @manifest_filename "inventory.etf"

  @type mode :: {:staging, [String.t()]} | :cache

  @spec validate(String.t(), mode(), keyword()) ::
          :miss | {:ok, ArtifactInventory.t()} | {:error, ArtifactInventory.validation_error()}
  def validate(dir, mode, opts) do
    case snapshot_directory(dir, mode, opts) do
      :miss ->
        :miss

      {:ok, snapshot} ->
        validate_copied_snapshot(snapshot, mode, opts)

      {:error, _reason} = error ->
        error
    end
  end

  @spec validate_copied_snapshot(String.t(), mode(), keyword()) ::
          {:ok, ArtifactInventory.t()} | {:error, ArtifactInventory.validation_error()}
  defp validate_copied_snapshot(snapshot, mode, opts) do
    result =
      try do
        validate_snapshot(snapshot, mode, opts)
      rescue
        _error -> {:error, {:invalid_beam, "validation", :validator_exception}}
      catch
        _kind, _reason -> {:error, {:invalid_beam, "validation", :validator_failure}}
      end

    case result do
      {:ok, inventory} ->
        {:ok, inventory}

      {:error, _reason} = error ->
        File.rm_rf(snapshot)
        error
    end
  end

  @spec validate_snapshot(String.t(), mode(), keyword()) ::
          {:ok, ArtifactInventory.t()} | {:error, ArtifactInventory.validation_error()}
  defp validate_snapshot(snapshot, mode, opts) do
    report_path = Path.join(snapshot, ".validation-report-#{unique_suffix()}.json")
    timeout = Keyword.get(opts, :validation_timeout, @default_timeout)

    request = %{
      "snapshot" => snapshot,
      "report_path" => report_path,
      "mode" => encode_mode(mode),
      "options" =>
        Map.new(validator_opts(opts), fn {key, value} -> {Atom.to_string(key), value} end)
    }

    result =
      with :ok <- disposable_validate(request, snapshot, timeout),
           {:ok, report} <- read_report(report_path) do
        materialize(snapshot, report, opts)
      end

    File.rm(report_path)
    result
  end

  @spec disposable_validate(map(), String.t(), timeout()) ::
          :ok | {:error, ArtifactInventory.validation_error()}
  defp disposable_validate(request, snapshot, timeout) do
    case DisposableBeam.run(:validator, request, Path.dirname(snapshot), timeout) do
      :ok -> :ok
      {:error, :timeout} -> {:error, {:invalid_beam, "validation", :validator_timeout}}
      {:error, reason} -> {:error, {:invalid_beam, "validation", {:validator_failed, reason}}}
    end
  end

  @doc false
  @spec run_disposable(map()) :: :ok
  def run_disposable(%{
        "snapshot" => snapshot,
        "report_path" => report_path,
        "mode" => encoded_mode,
        "options" => encoded_opts
      })
      when is_binary(snapshot) and is_binary(report_path) and is_map(encoded_opts) do
    with {:ok, mode} <- decode_mode(encoded_mode),
         {:ok, opts} <- decode_options(encoded_opts) do
      validate_in_disposable(snapshot, report_path, mode, opts)
    else
      {:error, _reason} -> :ok
    end
  end

  def run_disposable(_request), do: :ok

  @spec validate_in_disposable(String.t(), String.t(), mode(), keyword()) :: :ok
  defp validate_in_disposable(snapshot, report_path, mode, opts) do
    result =
      try do
        ArtifactInventory.validate_in_disposable(snapshot, mode, opts)
      rescue
        _error -> {:error, {:invalid_beam, "validation", :validator_exception}}
      catch
        _kind, _reason -> {:error, {:invalid_beam, "validation", :validator_failure}}
      end

    payload = encode_peer_result(result)
    binary = JSON.encode!(payload)

    final =
      if byte_size(binary) <= @max_report_bytes,
        do: binary,
        else: JSON.encode!(%{"status" => "error", "code" => "validation_report_too_large"})

    temporary = report_path <> ".worker-tmp"

    with :ok <- File.write(temporary, final, [:binary, :exclusive]),
         :ok <- File.rename(temporary, report_path) do
      :ok
    else
      {:error, _reason} ->
        File.rm(temporary)
        :ok
    end
  end

  @spec encode_peer_result({:ok, ArtifactInventory.t()} | {:error, term()}) :: map()
  defp encode_peer_result({:ok, inventory}) do
    %{
      "status" => "ok",
      "fingerprint" => Base.encode64(inventory.fingerprint),
      "artifacts" =>
        Enum.map(inventory.artifacts, fn artifact ->
          %{
            "filename" => artifact.filename,
            "module_name" => artifact.module_name,
            "digest" => Base.encode64(artifact.digest),
            "byte_size" => artifact.byte_size,
            "atom_count" => artifact.atom_count
          }
        end)
    }
  end

  defp encode_peer_result({:error, reason}) do
    %{"status" => "error", "reason" => sanitize_reason(reason)}
  end

  @spec sanitize_reason(term()) :: map()
  defp sanitize_reason(reason) do
    # Error data is diagnostic only. The host reconstructs no atoms from it.
    %{"text" => inspect(reason, limit: 20, printable_limit: 4_096, width: 80)}
  end

  @spec read_report(String.t()) :: {:ok, map()} | {:error, ArtifactInventory.validation_error()}
  defp read_report(path) do
    with {:ok, binary} <- SecureFile.read(path, @max_report_bytes),
         {:ok, decoded} <- JSON.decode(binary) do
      case decoded do
        %{"status" => "ok", "fingerprint" => fingerprint, "artifacts" => artifacts}
        when is_binary(fingerprint) and is_list(artifacts) ->
          {:ok, decoded}

        %{"status" => "error", "reason" => %{"text" => text}} when is_binary(text) ->
          {:error, {:invalid_beam, "validation", text}}

        %{"status" => "error", "code" => code} when is_binary(code) ->
          {:error, {:invalid_beam, "validation", code}}

        _other ->
          {:error, {:invalid_beam, "validation", :invalid_validator_report}}
      end
    else
      {:error, reason} -> {:error, {:invalid_beam, "validation", reason}}
    end
  end

  @spec materialize(String.t(), map(), keyword()) ::
          {:ok, ArtifactInventory.t()} | {:error, ArtifactInventory.validation_error()}
  defp materialize(snapshot, report, opts) do
    max_artifacts = limit(opts, :max_artifacts, 128)
    max_artifact_bytes = limit(opts, :max_artifact_bytes, 16 * 1024 * 1024)
    max_total_bytes = limit(opts, :max_total_bytes, 64 * 1024 * 1024)
    max_total_atoms = limit(opts, :max_total_atoms, 16_384)
    atom_reserve = limit(opts, :host_atom_reserve, 65_536)
    artifacts = report["artifacts"]

    with :ok <- bounded_count(artifacts, max_artifacts),
         {:ok, fingerprint} <- decode_digest(report["fingerprint"]),
         {:ok, total_atoms} <-
           prevalidate_totals(
             artifacts,
             max_artifact_bytes,
             max_total_bytes,
             max_total_atoms
           ),
         :ok <- validate_atom_capacity(total_atoms, atom_reserve),
         {:ok, materialized, _total_bytes, ^total_atoms} <-
           materialize_artifacts(
             snapshot,
             artifacts,
             max_artifact_bytes,
             max_total_bytes,
             max_total_atoms
           ) do
      {:ok,
       %ArtifactInventory{
         artifacts: materialized,
         fingerprint: fingerprint,
         snapshot_dir: snapshot
       }}
    end
  end

  @spec bounded_count([term()], pos_integer()) ::
          :ok | {:error, ArtifactInventory.validation_error()}
  defp bounded_count([], _max), do: {:error, :empty_inventory}

  defp bounded_count(artifacts, max) do
    count = length(artifacts)
    if count <= max, do: :ok, else: {:error, {:artifact_limit_exceeded, count, max}}
  end

  @spec prevalidate_totals([term()], pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, ArtifactInventory.validation_error()}
  defp prevalidate_totals(metadata, max_artifact, max_total, max_atoms) do
    metadata
    |> Enum.reduce_while({:ok, 0, 0}, fn
      %{"byte_size" => size, "atom_count" => atoms}, {:ok, total_bytes, total_atoms}
      when is_integer(size) and size >= 0 and is_integer(atoms) and atoms >= 0 ->
        next_bytes = total_bytes + size
        next_atoms = total_atoms + atoms

        result =
          if size > max_artifact,
            do: {:error, {:artifact_too_large, "validation", size, max_artifact}},
            else: validate_totals(next_bytes, next_atoms, max_total, max_atoms)

        case result do
          :ok -> {:cont, {:ok, next_bytes, next_atoms}}
          {:error, _reason} = error -> {:halt, error}
        end

      _metadata, _acc ->
        {:halt, {:error, {:cache_manifest_invalid, :invalid_artifact_metadata}}}
    end)
    |> case do
      {:ok, _bytes, atoms} -> {:ok, atoms}
      {:error, _reason} = error -> error
    end
  end

  @spec materialize_artifacts(String.t(), [term()], pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, [Artifact.t()], non_neg_integer(), non_neg_integer()}
          | {:error, ArtifactInventory.validation_error()}
  defp materialize_artifacts(snapshot, metadata, max_artifact, max_total, max_atoms) do
    metadata
    |> Enum.reduce_while({:ok, [], 0, 0}, fn item, state ->
      snapshot
      |> materialize_artifact(item, max_artifact)
      |> accumulate_materialized_artifact(state, max_total, max_atoms)
    end)
    |> case do
      {:ok, artifacts, bytes, atoms} -> {:ok, Enum.reverse(artifacts), bytes, atoms}
      {:error, _reason} = error -> error
    end
  end

  @spec accumulate_materialized_artifact(
          {:ok, Artifact.t()} | {:error, ArtifactInventory.validation_error()},
          {:ok, [Artifact.t()], non_neg_integer(), non_neg_integer()},
          pos_integer(),
          pos_integer()
        ) ::
          {:cont, {:ok, [Artifact.t()], non_neg_integer(), non_neg_integer()}}
          | {:halt, {:error, ArtifactInventory.validation_error()}}
  defp accumulate_materialized_artifact(
         {:ok, artifact},
         {:ok, acc, bytes, atoms},
         max_total,
         max_atoms
       ) do
    next_bytes = bytes + artifact.byte_size
    next_atoms = atoms + artifact.atom_count

    case validate_totals(next_bytes, next_atoms, max_total, max_atoms) do
      :ok -> {:cont, {:ok, [artifact | acc], next_bytes, next_atoms}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp accumulate_materialized_artifact(
         {:error, _reason} = error,
         _state,
         _max_total,
         _max_atoms
       ),
       do: {:halt, error}

  @spec materialize_artifact(String.t(), term(), pos_integer()) ::
          {:ok, Artifact.t()} | {:error, ArtifactInventory.validation_error()}
  defp materialize_artifact(
         snapshot,
         %{
           "filename" => filename,
           "module_name" => module_name,
           "digest" => encoded_digest,
           "byte_size" => declared_size,
           "atom_count" => atom_count
         },
         max_bytes
       )
       when is_binary(filename) and is_binary(module_name) and is_integer(declared_size) and
              declared_size >= 0 and is_integer(atom_count) and atom_count >= 0 do
    path = Path.join(snapshot, filename)

    with true <- safe_name?(filename, 262),
         true <- safe_name?(module_name, 255),
         true <- filename == module_name <> ".beam",
         {:ok, digest} <- decode_digest(encoded_digest),
         {:ok, bytecode} <- read_artifact(path, filename, max_bytes),
         true <- byte_size(bytecode) == declared_size,
         true <- :crypto.hash(:sha256, bytecode) == digest do
      module = String.to_atom(module_name)

      {:ok,
       %Artifact{
         module: module,
         module_name: module_name,
         filename: filename,
         path: path,
         bytecode: bytecode,
         digest: digest,
         byte_size: declared_size,
         atom_count: atom_count
       }}
    else
      false -> {:error, {:cache_manifest_mismatch, filename}}
      {:error, _reason} = error -> error
    end
  end

  defp materialize_artifact(_snapshot, _metadata, _max_bytes),
    do: {:error, {:cache_manifest_invalid, :invalid_artifact_metadata}}

  @spec read_artifact(String.t(), String.t(), pos_integer()) ::
          {:ok, binary()} | {:error, ArtifactInventory.validation_error()}
  defp read_artifact(path, filename, max_bytes) do
    case SecureFile.read(path, max_bytes) do
      {:ok, binary} ->
        {:ok, binary}

      {:error, {:file_too_large, _path, size, max}} ->
        {:error, {:artifact_too_large, filename, size, max}}

      {:error, {:non_regular_file, _path, type}} ->
        {:error, {:non_regular_artifact_entry, filename, type}}

      {:error, reason} ->
        {:error, {:artifact_read_failed, filename, reason}}
    end
  end

  @spec validate_totals(non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()) ::
          :ok | {:error, ArtifactInventory.validation_error()}
  defp validate_totals(bytes, _atoms, max_bytes, _max_atoms) when bytes > max_bytes,
    do: {:error, {:total_artifact_bytes_exceeded, bytes, max_bytes}}

  defp validate_totals(_bytes, atoms, _max_bytes, max_atoms) when atoms > max_atoms,
    do: {:error, {:total_atom_limit_exceeded, atoms, max_atoms}}

  defp validate_totals(_bytes, _atoms, _max_bytes, _max_atoms), do: :ok

  @spec validate_atom_capacity(non_neg_integer(), pos_integer()) ::
          :ok | {:error, ArtifactInventory.validation_error()}
  defp validate_atom_capacity(atoms, reserve) do
    current = :erlang.system_info(:atom_count)
    atom_limit = :erlang.system_info(:atom_limit)

    if current + atoms + reserve <= atom_limit,
      do: :ok,
      else: {:error, {:host_atom_capacity_exceeded, current, atoms, reserve, atom_limit}}
  end

  @spec decode_digest(term()) :: {:ok, binary()} | {:error, ArtifactInventory.validation_error()}
  defp decode_digest(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, digest} when byte_size(digest) == 32 -> {:ok, digest}
      _other -> {:error, {:cache_manifest_invalid, :invalid_digest}}
    end
  end

  defp decode_digest(_encoded), do: {:error, {:cache_manifest_invalid, :invalid_digest}}

  @spec snapshot_directory(String.t(), mode(), keyword()) ::
          :miss | {:ok, String.t()} | {:error, ArtifactInventory.validation_error()}
  defp snapshot_directory(dir, mode, opts) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} -> copy_directory(dir, mode, opts)
      {:ok, %File.Stat{type: type}} -> {:error, {:non_regular_cache_directory, dir, type}}
      {:error, :enoent} when mode == :cache -> :miss
      {:error, reason} -> {:error, {:artifact_read_failed, dir, reason}}
    end
  end

  @spec copy_directory(String.t(), mode(), keyword()) ::
          {:ok, String.t()} | {:error, ArtifactInventory.validation_error()}
  defp copy_directory(dir, mode, opts) do
    with {:ok, entries} <- File.ls(dir),
         :ok <- validate_snapshot_entries(entries, mode, opts),
         {:ok, snapshot} <- make_snapshot_dir(Path.dirname(dir)),
         :ok <- copy_entries(dir, snapshot, Enum.sort(entries), opts) do
      {:ok, snapshot}
    else
      {:error, reason} when is_atom(reason) -> {:error, {:artifact_read_failed, dir, reason}}
      {:error, _reason} = error -> error
    end
  end

  @spec validate_snapshot_entries([String.t()], mode(), keyword()) ::
          :ok | {:error, ArtifactInventory.validation_error()}
  defp validate_snapshot_entries(entries, mode, opts) do
    allowed_manifest = if mode == :cache, do: [@manifest_filename], else: []
    beams = Enum.filter(entries, &String.ends_with?(&1, ".beam"))
    unexpected = entries -- (beams ++ allowed_manifest)
    max = limit(opts, :max_artifacts, 128)

    case unexpected do
      [entry | _rest] -> {:error, {:unexpected_artifact_entry, entry}}
      [] -> validate_snapshot_beams(beams, max)
    end
  end

  @spec validate_snapshot_beams([String.t()], pos_integer()) ::
          :ok | {:error, ArtifactInventory.validation_error()}
  defp validate_snapshot_beams([], _max), do: {:error, :empty_inventory}

  defp validate_snapshot_beams(beams, max) do
    count = Enum.count_until(beams, max + 1)

    if count > max,
      do: {:error, {:artifact_limit_exceeded, count, max}},
      else: :ok
  end

  @spec make_snapshot_dir(String.t()) ::
          {:ok, String.t()} | {:error, ArtifactInventory.validation_error()}
  defp make_snapshot_dir(parent) do
    dir = Path.join(parent, ".minga-artifact-validation-#{unique_suffix()}")

    case File.mkdir(dir) do
      :ok ->
        case File.chmod(dir, 0o700) do
          :ok ->
            {:ok, dir}

          {:error, reason} ->
            File.rm_rf(dir)
            {:error, {:artifact_read_failed, dir, reason}}
        end

      {:error, reason} ->
        {:error, {:artifact_read_failed, dir, reason}}
    end
  end

  @spec copy_entries(String.t(), String.t(), [String.t()], keyword()) ::
          :ok | {:error, ArtifactInventory.validation_error()}
  defp copy_entries(source, snapshot, entries, opts) do
    max_artifact = limit(opts, :max_artifact_bytes, 16 * 1024 * 1024)
    max_manifest = limit(opts, :max_manifest_bytes, 1_048_576)
    max_total = limit(opts, :max_total_bytes, 64 * 1024 * 1024)

    entries
    |> Enum.reduce_while({:ok, 0}, fn entry, {:ok, total} ->
      max = if entry == @manifest_filename, do: max_manifest, else: max_artifact
      copy_entry(source, snapshot, entry, total, max, max_total)
    end)
    |> case do
      {:ok, _total} ->
        :ok

      {:error, _reason} = error ->
        File.rm_rf(snapshot)
        error
    end
  end

  @spec copy_entry(
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          pos_integer(),
          pos_integer()
        ) :: {:cont, {:ok, non_neg_integer()}} | {:halt, {:error, term()}}
  defp copy_entry(source, snapshot, entry, total, max, max_total) do
    source
    |> Path.join(entry)
    |> SecureFile.read(max)
    |> copy_entry_result(snapshot, entry, total, max_total)
  end

  @spec copy_entry_result(
          {:ok, binary()} | {:error, SecureFile.read_error()},
          String.t(),
          String.t(),
          non_neg_integer(),
          pos_integer()
        ) :: {:cont, {:ok, non_neg_integer()}} | {:halt, {:error, term()}}
  defp copy_entry_result({:ok, binary}, snapshot, entry, total, max_total)
       when total + byte_size(binary) <= max_total do
    destination = Path.join(snapshot, entry)

    case File.write(destination, binary, [:binary, :exclusive]) do
      :ok -> {:cont, {:ok, total + byte_size(binary)}}
      {:error, reason} -> {:halt, {:error, {:artifact_read_failed, entry, reason}}}
    end
  end

  defp copy_entry_result({:ok, binary}, _snapshot, _entry, total, max_total),
    do: {:halt, {:error, {:total_artifact_bytes_exceeded, total + byte_size(binary), max_total}}}

  defp copy_entry_result(
         {:error, {:file_too_large, _path, size, file_max}},
         _snapshot,
         @manifest_filename,
         _total,
         _max_total
       ),
       do: {:halt, {:error, {:cache_manifest_invalid, {:too_large, size, file_max}}}}

  defp copy_entry_result(
         {:error, {:file_too_large, _path, size, file_max}},
         _snapshot,
         entry,
         _total,
         _max_total
       ),
       do: {:halt, {:error, {:artifact_too_large, entry, size, file_max}}}

  defp copy_entry_result(
         {:error, {:non_regular_file, _path, type}},
         _snapshot,
         entry,
         _total,
         _max_total
       ),
       do: {:halt, {:error, {:non_regular_artifact_entry, entry, type}}}

  defp copy_entry_result({:error, reason}, _snapshot, entry, _total, _max_total),
    do: {:halt, {:error, {:artifact_read_failed, entry, reason}}}

  @spec safe_name?(String.t(), pos_integer()) :: boolean()
  defp safe_name?(name, max) do
    name != "" and String.valid?(name) and byte_size(name) <= max and Path.basename(name) == name and
      not String.contains?(name, ["/", "\\", <<0>>])
  end

  @spec encode_mode(mode()) :: map()
  defp encode_mode(:cache), do: %{"type" => "cache"}

  defp encode_mode({:staging, expected_modules}),
    do: %{"type" => "staging", "expected_modules" => expected_modules}

  @spec decode_mode(term()) :: {:ok, mode()} | {:error, :invalid_mode}
  defp decode_mode(%{"type" => "cache"}), do: {:ok, :cache}

  defp decode_mode(%{"type" => "staging", "expected_modules" => modules})
       when is_list(modules) do
    if Enum.all?(modules, &is_binary/1),
      do: {:ok, {:staging, modules}},
      else: {:error, :invalid_mode}
  end

  defp decode_mode(_mode), do: {:error, :invalid_mode}

  @spec decode_options(map()) :: {:ok, keyword()} | {:error, :invalid_options}
  defp decode_options(options) do
    allowed = Map.new(validator_option_keys(), &{Atom.to_string(&1), &1})

    Enum.reduce_while(options, {:ok, []}, fn
      {key, value}, {:ok, acc} when is_binary(key) and is_integer(value) and value > 0 ->
        case Map.fetch(allowed, key) do
          {:ok, option} -> {:cont, {:ok, [{option, value} | acc]}}
          :error -> {:halt, {:error, :invalid_options}}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_options}}
    end)
  end

  @spec validator_opts(keyword()) :: keyword()
  defp validator_opts(opts), do: Keyword.take(opts, validator_option_keys())

  @spec validator_option_keys() :: [atom()]
  defp validator_option_keys do
    [
      :max_artifacts,
      :max_artifact_bytes,
      :max_total_bytes,
      :max_atoms_per_artifact,
      :max_total_atoms,
      :max_atom_name_bytes,
      :max_manifest_bytes,
      :max_decompressed_bytes,
      :max_total_decompressed_bytes
    ]
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
end
