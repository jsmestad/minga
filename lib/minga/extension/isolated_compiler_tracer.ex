defmodule Minga.Extension.IsolatedCompilerTracer do
  @moduledoc false

  @config_key {__MODULE__, :config}
  @max_module_name_bytes 255

  @doc "Returns the peer-local persistent-term key used by the compiler tracer."
  @spec config_key() :: term()
  def config_key, do: @config_key

  @doc "Persists each compiler emission without permitting a later emission to overwrite it."
  @spec trace(term(), Macro.Env.t()) :: :ok
  def trace({:on_module, bytecode, _warnings}, %Macro.Env{module: module})
      when is_atom(module) and is_binary(bytecode) do
    case :persistent_term.get(@config_key, :undefined) do
      %{tracker: tracker} when is_pid(tracker) -> emit_artifact!(tracker, module, bytecode)
      :undefined -> :ok
    end
  end

  def trace(_event, _env), do: :ok

  @spec emit_artifact!(pid(), module(), binary()) :: :ok
  defp emit_artifact!(tracker, module, bytecode) do
    module_name = Atom.to_string(module)

    if valid_filename_module?(module_name) do
      ref = make_ref()
      send(tracker, {:compiler_emission, self(), ref, module, bytecode})

      receive do
        {:compiler_emission_result, ^ref, :ok} ->
          :ok

        {:compiler_emission_result, ^ref, {:error, reason}} ->
          raise "artifact write failed for #{module_name}: #{reason}"
      after
        5_000 -> raise "artifact write timed out for #{module_name}"
      end
    else
      raise "invalid compiler module name"
    end
  end

  @spec valid_filename_module?(String.t()) :: boolean()
  defp valid_filename_module?(module_name) do
    module_name != "" and byte_size(module_name) <= @max_module_name_bytes and
      String.valid?(module_name) and not String.contains?(module_name, ["/", "\\", <<0>>]) and
      Path.basename(module_name) == module_name
  end
end
