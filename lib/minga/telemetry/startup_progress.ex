defmodule Minga.Telemetry.StartupProgress do
  @moduledoc "Reports isolated extension compilation while the editor is still starting."

  @compile_event [:minga, :extension, :compile]
  @native_prefix "MINGA_STARTUP_COMPILE\t"
  @hex_trace __MODULE__
  @typep destination :: :native | :terminal

  @doc false
  @spec during_config_load((-> result)) :: result when result: var
  def during_config_load(load) when is_function(load, 0) do
    case destination() do
      nil -> load.()
      mode -> report_during(load, mode)
    end
  end

  @doc false
  @spec during_hex_install([atom()], (-> result)) :: result when result: var
  def during_hex_install(applications, install) do
    case Process.get(__MODULE__) do
      nil -> install.()
      mode -> trace_hex_install(applications, install, mode)
    end
  end

  @doc false
  @spec trace(term(), Macro.Env.t()) :: :ok
  def trace(:start, %Macro.Env{}) do
    app = Mix.Project.config()[:app]

    case :ets.lookup(@hex_trace, app) do
      [{^app, mode}] ->
        if :ets.take(@hex_trace, app) != [] do
          :ets.insert(@hex_trace, {{:reported}, true})
          report_compiling(app, mode)
        end

        :ok

      _ ->
        :ok
    end
  end

  def trace(_event, _env), do: :ok

  @spec trace_hex_install([atom()], (-> result), destination()) :: result when result: var
  defp trace_hex_install(applications, install, mode) do
    table = :ets.new(@hex_trace, [:named_table, :public])
    :ets.insert(table, Enum.map(applications, &{&1, mode}))
    tracers = Code.get_compiler_option(:tracers)
    Code.put_compiler_option(:tracers, [__MODULE__ | tracers])

    try do
      install.()
    after
      Code.put_compiler_option(:tracers, tracers)
      if mode == :native and :ets.member(table, {:reported}), do: write_native(nil)
      :ets.delete(table)
    end
  end

  @spec destination() :: destination() | nil
  defp destination do
    case System.get_env("MINGA_BOOT_PROGRESS") do
      "native" -> :native
      "terminal" -> :terminal
      _other -> nil
    end
  end

  @doc false
  @spec handle_compile([atom()], map(), map(), destination()) :: :ok
  def handle_compile(
        @compile_event ++ [:start],
        _measurements,
        %{source: {:extension, name}},
        mode
      ) do
    report_compiling(name, mode)
  end

  def handle_compile(@compile_event ++ [phase], _measurements, _metadata, :native)
      when phase in [:stop, :exception],
      do: write_native(nil)

  def handle_compile(_event, _measurements, _metadata, _mode), do: :ok

  @spec report_compiling(atom(), destination()) :: :ok
  defp report_compiling(name, :native), do: write_native(Atom.to_string(name))

  defp report_compiling(name, :terminal),
    do: write_terminal("Compiling extension #{inspect(name)}\n")

  @spec report_during((-> result), destination()) :: result when result: var
  defp report_during(load, mode) do
    id = {__MODULE__, self()}
    events = for phase <- [:start, :stop, :exception], do: @compile_event ++ [phase]
    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_compile/4, mode)
    previous = Process.put(__MODULE__, mode)

    try do
      load.()
    after
      :telemetry.detach(id)
      if previous, do: Process.put(__MODULE__, previous), else: Process.delete(__MODULE__)
    end
  end

  @spec write_native(String.t() | nil) :: :ok
  defp write_native(name) do
    _result = :io.put_chars(:standard_error, [@native_prefix, JSON.encode!(%{name: name}), "\n"])
    :ok
  end

  @spec write_terminal(String.t()) :: :ok
  defp write_terminal(message) do
    # A source launch redirects stdout and stderr to the log before starting Mix.
    # This is the controlling terminal, never a configurable file path.
    _result = File.write("/dev/tty", message)
    :ok
  end
end
