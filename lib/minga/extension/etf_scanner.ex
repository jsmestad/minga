defmodule Minga.Extension.EtfScanner do
  @moduledoc false

  @version 131
  @compressed 80
  @max_depth 256

  @type limits :: %{
          required(:max_atoms) => pos_integer(),
          required(:max_atom_name_bytes) => pos_integer(),
          required(:max_decompressed_bytes) => pos_integer()
        }
  @type scan_result ::
          {:ok, %{atom_count: non_neg_integer(), decompressed_bytes: non_neg_integer()}}
          | {:error, term()}
  @typep state :: %{
           atoms: non_neg_integer(),
           decompressed: non_neg_integer(),
           terms: non_neg_integer(),
           max_atoms: pos_integer(),
           max_name: pos_integer(),
           max_decompressed: pos_integer(),
           max_terms: pos_integer()
         }

  @doc "Structurally scans exactly one external term without creating atoms."
  @spec scan_external(binary(), limits()) :: scan_result()
  def scan_external(<<@version, term::binary>>, limits) do
    case parse_term(term, initial_state(limits), 0) do
      {:ok, <<>>, scanned} -> result(scanned)
      {:ok, _trailing, _state} -> {:error, :etf_trailing_bytes}
      {:error, _reason} = error -> error
    end
  end

  def scan_external(_binary, _limits), do: {:error, :missing_etf_version}

  @doc "Inflates and structurally scans a complete BEAM LitT literal table."
  @spec scan_literal_table(binary(), limits()) :: scan_result()
  def scan_literal_table(<<0::unsigned-big-32, uncompressed::binary>>, limits) do
    with :ok <- declared_limit(byte_size(uncompressed), limits.max_decompressed_bytes),
         {:ok, state} <- parse_literal_entries(uncompressed, initial_state(limits)) do
      result(%{state | decompressed: byte_size(uncompressed)})
    end
  end

  def scan_literal_table(<<declared::unsigned-big-32, compressed::binary>>, limits) do
    with :ok <- declared_limit(declared, limits.max_decompressed_bytes),
         {:ok, inflated} <- inflate_exact(compressed, declared, limits.max_decompressed_bytes),
         {:ok, state} <- parse_literal_entries(inflated, initial_state(limits)) do
      result(%{state | decompressed: state.decompressed + byte_size(inflated)})
    end
  end

  def scan_literal_table(_binary, _limits), do: {:error, :truncated_literal_table}

  @spec initial_state(limits()) :: state()
  defp initial_state(limits) do
    %{
      atoms: 0,
      decompressed: 0,
      terms: 0,
      max_atoms: limits.max_atoms,
      max_name: limits.max_atom_name_bytes,
      max_decompressed: limits.max_decompressed_bytes,
      max_terms: limits.max_decompressed_bytes
    }
  end

  @spec result(state()) :: scan_result()
  defp result(state),
    do: {:ok, %{atom_count: state.atoms, decompressed_bytes: state.decompressed}}

  @spec parse_literal_entries(binary(), state()) :: {:ok, state()} | {:error, term()}
  defp parse_literal_entries(<<count::unsigned-big-32, entries::binary>>, state) do
    parse_literals(entries, count, state)
  end

  defp parse_literal_entries(_binary, _state), do: {:error, :truncated_literal_count}

  @spec parse_literals(binary(), non_neg_integer(), state()) :: {:ok, state()} | {:error, term()}
  defp parse_literals(<<>>, 0, state), do: {:ok, state}
  defp parse_literals(_trailing, 0, _state), do: {:error, :literal_table_trailing_bytes}

  defp parse_literals(<<size::unsigned-big-32, rest::binary>>, remaining, state)
       when remaining > 0 and byte_size(rest) >= size do
    <<encoded::binary-size(^size), tail::binary>> = rest

    case encoded do
      <<@version, term::binary>> ->
        case parse_term(term, state, 0) do
          {:ok, <<>>, next_state} -> parse_literals(tail, remaining - 1, next_state)
          {:ok, _trailing, _next_state} -> {:error, :literal_etf_trailing_bytes}
          {:error, _reason} = error -> error
        end

      _other ->
        {:error, :invalid_literal_etf}
    end
  end

  defp parse_literals(_binary, _remaining, _state), do: {:error, :truncated_literal_entry}

  @spec parse_term(binary(), state(), non_neg_integer()) ::
          {:ok, binary(), state()} | {:error, term()}
  defp parse_term(_binary, _state, depth) when depth > @max_depth,
    do: {:error, :etf_nesting_limit_exceeded}

  defp parse_term(binary, state, depth) do
    with {:ok, next_state} <- count_term(state) do
      do_parse_term(binary, next_state, depth)
    end
  end

  @spec do_parse_term(binary(), state(), non_neg_integer()) ::
          {:ok, binary(), state()} | {:error, term()}
  defp do_parse_term(<<70, _float::binary-size(8), rest::binary>>, state, _depth),
    do: {:ok, rest, state}

  defp do_parse_term(<<77, size::unsigned-big-32, bits, rest::binary>>, state, _depth)
       when bits in 1..8,
       do: skip(rest, size, state)

  defp do_parse_term(<<@compressed, declared::unsigned-big-32, compressed::binary>>, state, depth) do
    remaining_limit = state.max_decompressed - state.decompressed

    with :ok <- declared_limit(declared, remaining_limit),
         {:ok, inflated} <- inflate_exact(compressed, declared, remaining_limit),
         {:ok, <<>>, scanned} <- parse_term(inflated, state, depth + 1) do
      {:ok, <<>>, %{scanned | decompressed: scanned.decompressed + byte_size(inflated)}}
    else
      {:ok, _trailing, _state} -> {:error, :compressed_etf_trailing_bytes}
      {:error, _reason} = error -> error
    end
  end

  defp do_parse_term(<<82, _index, _rest::binary>>, _state, _depth),
    do: {:error, :atom_cache_ref_not_allowed}

  defp do_parse_term(<<88, rest::binary>>, state, depth),
    do: parse_node_and_fixed(rest, 12, state, depth)

  defp do_parse_term(<<89, rest::binary>>, state, depth),
    do: parse_node_and_fixed(rest, 8, state, depth)

  defp do_parse_term(<<90, count::unsigned-big-16, rest::binary>>, state, depth),
    do: parse_node_and_fixed(rest, 4 + count * 4, state, depth)

  defp do_parse_term(<<97, _value, rest::binary>>, state, _depth), do: {:ok, rest, state}

  defp do_parse_term(<<98, _value::signed-big-32, rest::binary>>, state, _depth),
    do: {:ok, rest, state}

  defp do_parse_term(<<99, _float::binary-size(31), rest::binary>>, state, _depth),
    do: {:ok, rest, state}

  defp do_parse_term(<<100, size::unsigned-big-16, rest::binary>>, state, _depth),
    do: parse_atom(rest, size, :latin1, state)

  defp do_parse_term(<<101, rest::binary>>, state, depth),
    do: parse_node_and_fixed(rest, 5, state, depth)

  defp do_parse_term(<<102, rest::binary>>, state, depth),
    do: parse_node_and_fixed(rest, 5, state, depth)

  defp do_parse_term(<<103, rest::binary>>, state, depth),
    do: parse_node_and_fixed(rest, 9, state, depth)

  defp do_parse_term(<<104, arity, rest::binary>>, state, depth),
    do: parse_terms(rest, arity, state, depth + 1)

  defp do_parse_term(<<105, arity::unsigned-big-32, rest::binary>>, state, depth),
    do: parse_terms(rest, arity, state, depth + 1)

  defp do_parse_term(<<106, rest::binary>>, state, _depth), do: {:ok, rest, state}

  defp do_parse_term(<<107, size::unsigned-big-16, rest::binary>>, state, _depth),
    do: skip(rest, size, state)

  defp do_parse_term(<<108, length::unsigned-big-32, rest::binary>>, state, depth) do
    with {:ok, after_elements, elements_state} <- parse_terms(rest, length, state, depth + 1) do
      parse_term(after_elements, elements_state, depth + 1)
    end
  end

  defp do_parse_term(<<109, size::unsigned-big-32, rest::binary>>, state, _depth),
    do: skip(rest, size, state)

  defp do_parse_term(<<110, size, _sign, rest::binary>>, state, _depth),
    do: skip(rest, size, state)

  defp do_parse_term(<<111, size::unsigned-big-32, _sign, rest::binary>>, state, _depth),
    do: skip(rest, size, state)

  defp do_parse_term(<<112, size::unsigned-big-32, rest::binary>>, state, depth)
       when size >= 29 and byte_size(rest) >= size - 4 do
    payload_size = size - 4
    <<payload::binary-size(^payload_size), tail::binary>> = rest

    with <<_arity, _uniq::binary-size(16), _index::unsigned-big-32, free_count::unsigned-big-32,
           terms::binary>> <- payload,
         {:ok, <<>>, scanned} <- parse_terms(terms, free_count + 4, state, depth + 1) do
      {:ok, tail, scanned}
    else
      _other -> {:error, :invalid_new_fun_ext}
    end
  end

  defp do_parse_term(<<113, rest::binary>>, state, depth),
    do: parse_terms(rest, 3, state, depth + 1)

  defp do_parse_term(<<114, count::unsigned-big-16, rest::binary>>, state, depth),
    do: parse_node_and_fixed(rest, 1 + count * 4, state, depth)

  defp do_parse_term(<<115, size, rest::binary>>, state, _depth),
    do: parse_atom(rest, size, :latin1, state)

  defp do_parse_term(<<116, arity::unsigned-big-32, rest::binary>>, state, depth),
    do: parse_terms(rest, arity * 2, state, depth + 1)

  defp do_parse_term(<<117, free_count::unsigned-big-32, rest::binary>>, state, depth),
    do: parse_terms(rest, free_count + 4, state, depth + 1)

  defp do_parse_term(<<118, size::unsigned-big-16, rest::binary>>, state, _depth),
    do: parse_atom(rest, size, :utf8, state)

  defp do_parse_term(<<119, size, rest::binary>>, state, _depth),
    do: parse_atom(rest, size, :utf8, state)

  defp do_parse_term(<<120, rest::binary>>, state, depth),
    do: parse_node_and_fixed(rest, 12, state, depth)

  defp do_parse_term(<<121, _rest::binary>>, _state, _depth),
    do: {:error, :local_ext_not_allowed}

  defp do_parse_term(<<tag, _rest::binary>>, _state, _depth),
    do: {:error, {:unsupported_etf_tag, tag}}

  defp do_parse_term(<<>>, _state, _depth), do: {:error, :truncated_etf_term}

  @spec parse_node_and_fixed(binary(), non_neg_integer(), state(), non_neg_integer()) ::
          {:ok, binary(), state()} | {:error, term()}
  defp parse_node_and_fixed(binary, fixed_bytes, state, _depth) do
    with {:ok, rest, atom_state} <- parse_atom_term(binary, state),
         {:ok, tail, final_state} <- skip(rest, fixed_bytes, atom_state) do
      {:ok, tail, final_state}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec parse_atom_term(binary(), state()) :: {:ok, binary(), state()} | {:error, term()}
  defp parse_atom_term(<<100, size::unsigned-big-16, rest::binary>>, state),
    do: parse_atom(rest, size, :latin1, state)

  defp parse_atom_term(<<115, size, rest::binary>>, state),
    do: parse_atom(rest, size, :latin1, state)

  defp parse_atom_term(<<118, size::unsigned-big-16, rest::binary>>, state),
    do: parse_atom(rest, size, :utf8, state)

  defp parse_atom_term(<<119, size, rest::binary>>, state),
    do: parse_atom(rest, size, :utf8, state)

  defp parse_atom_term(<<82, _index, _rest::binary>>, _state),
    do: {:error, :atom_cache_ref_not_allowed}

  defp parse_atom_term(_binary, _state), do: {:error, :expected_atom_term}

  @spec parse_atom(binary(), non_neg_integer(), :latin1 | :utf8, state()) ::
          {:ok, binary(), state()} | {:error, term()}
  defp parse_atom(binary, size, encoding, state) when byte_size(binary) >= size do
    <<name::binary-size(^size), rest::binary>> = binary

    with :ok <- valid_atom_name(name, size, encoding, state.max_name),
         atoms = state.atoms + 1,
         :ok <- atom_limit(atoms, state.max_atoms) do
      {:ok, rest, %{state | atoms: atoms}}
    end
  end

  defp parse_atom(_binary, _size, _encoding, _state), do: {:error, :truncated_atom_name}

  @spec valid_atom_name(binary(), non_neg_integer(), :latin1 | :utf8, pos_integer()) ::
          :ok | {:error, term()}
  defp valid_atom_name(_name, 0, _encoding, _max), do: {:error, :empty_atom_name}

  defp valid_atom_name(_name, size, _encoding, max) when size > max,
    do: {:error, {:atom_name_too_large, size, max}}

  defp valid_atom_name(name, _size, :utf8, _max) do
    if String.valid?(name), do: :ok, else: {:error, :invalid_utf8_atom}
  end

  defp valid_atom_name(_name, _size, :latin1, _max), do: :ok

  @spec parse_terms(binary(), non_neg_integer(), state(), non_neg_integer()) ::
          {:ok, binary(), state()} | {:error, term()}
  defp parse_terms(binary, 0, state, _depth), do: {:ok, binary, state}

  defp parse_terms(binary, remaining, state, depth) when remaining > 0 do
    with {:ok, rest, next_state} <- parse_term(binary, state, depth) do
      parse_terms(rest, remaining - 1, next_state, depth)
    end
  end

  @spec skip(binary(), non_neg_integer(), state()) ::
          {:ok, binary(), state()} | {:error, :truncated_etf_term}
  defp skip(binary, size, state) when byte_size(binary) >= size do
    <<_discarded::binary-size(^size), rest::binary>> = binary
    {:ok, rest, state}
  end

  defp skip(_binary, _size, _state), do: {:error, :truncated_etf_term}

  @spec count_term(state()) :: {:ok, state()} | {:error, :etf_term_limit_exceeded}
  defp count_term(state) do
    terms = state.terms + 1

    if terms <= state.max_terms,
      do: {:ok, %{state | terms: terms}},
      else: {:error, :etf_term_limit_exceeded}
  end

  @spec atom_limit(non_neg_integer(), pos_integer()) :: :ok | {:error, term()}
  defp atom_limit(atoms, max) when atoms > max,
    do: {:error, {:etf_atom_limit_exceeded, atoms, max}}

  defp atom_limit(_atoms, _max), do: :ok

  @spec declared_limit(non_neg_integer(), integer()) :: :ok | {:error, term()}
  defp declared_limit(declared, max) when max < 0 or declared > max,
    do: {:error, {:decompressed_limit_exceeded, declared, max}}

  defp declared_limit(_declared, _max), do: :ok

  @spec inflate_exact(binary(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  defp inflate_exact(compressed, declared, max) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)

      with {:ok, inflated} <- inflate_chunks(z, compressed, declared, max, [], 0),
           :ok <- verify_zlib_boundary(compressed, inflated) do
        {:ok, inflated}
      end
    rescue
      _error -> {:error, :malformed_compressed_etf}
    catch
      _kind, _reason -> {:error, :malformed_compressed_etf}
    after
      safe_inflate_end(z)
      :zlib.close(z)
    end
  end

  @spec inflate_chunks(
          term(),
          binary(),
          non_neg_integer(),
          non_neg_integer(),
          [binary()],
          non_neg_integer()
        ) ::
          {:ok, binary()} | {:error, term()}
  defp inflate_chunks(z, input, declared, max, acc, total) do
    case :zlib.safeInflate(z, input) do
      {status, output} when status in [:continue, :finished] ->
        output_binary = IO.iodata_to_binary(output)
        next_total = total + byte_size(output_binary)

        case inflated_size(next_total, declared, max, status) do
          :continue when input == <<>> and output_binary == <<>> ->
            {:error, :truncated_compressed_etf}

          :continue ->
            inflate_chunks(z, <<>>, declared, max, [output_binary | acc], next_total)

          :finished ->
            {:ok, acc |> Enum.reverse([output_binary]) |> IO.iodata_to_binary()}

          {:error, _reason} = error ->
            error
        end
    end
  end

  @spec inflated_size(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          :continue | :finished
        ) ::
          :continue | :finished | {:error, term()}
  defp inflated_size(actual, _declared, max, _status) when actual > max,
    do: {:error, {:decompressed_limit_exceeded, actual, max}}

  defp inflated_size(actual, declared, _max, :finished) when actual != declared,
    do: {:error, {:decompressed_size_mismatch, declared, actual}}

  defp inflated_size(_actual, _declared, _max, :finished), do: :finished
  defp inflated_size(_actual, _declared, _max, :continue), do: :continue

  @spec verify_zlib_boundary(binary(), binary()) :: :ok | {:error, term()}
  defp verify_zlib_boundary(compressed, inflated) do
    checksum = <<:erlang.adler32(inflated)::unsigned-big-32>>
    candidates = :binary.matches(compressed, checksum)

    if Enum.count_until(candidates, 1_025) <= 1_024 do
      verify_zlib_candidates(compressed, inflated, candidates)
    else
      {:error, :ambiguous_compressed_etf_boundary}
    end
  end

  @spec verify_zlib_candidates(binary(), binary(), [{non_neg_integer(), pos_integer()}]) ::
          :ok | {:error, term()}
  defp verify_zlib_candidates(compressed, inflated, [{offset, 4} | rest]) do
    end_offset = offset + 4
    candidate = binary_part(compressed, 0, end_offset)

    if valid_zlib_candidate?(candidate, inflated) do
      if end_offset == byte_size(compressed),
        do: :ok,
        else: {:error, :compressed_etf_trailing_bytes}
    else
      verify_zlib_candidates(compressed, inflated, rest)
    end
  end

  defp verify_zlib_candidates(_compressed, _inflated, []),
    do: {:error, :malformed_compressed_etf}

  @spec valid_zlib_candidate?(binary(), binary()) :: boolean()
  defp valid_zlib_candidate?(candidate, inflated) do
    :zlib.uncompress(candidate) == inflated
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  @spec safe_inflate_end(term()) :: :ok
  defp safe_inflate_end(z) do
    :zlib.inflateEnd(z)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end
end
