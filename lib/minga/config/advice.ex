defmodule Minga.Config.Advice do
  @moduledoc """
  Before/after/around/override advice for editor commands.

  Advice functions wrap existing command execution, similar to Emacs's
  `advice-add` system. Four phases are supported:

  | Phase | Signature | Behavior |
  |-------|-----------|----------|
  | `:before` | `(state -> state)` | Transforms state before the command runs |
  | `:after` | `(state -> state)` | Transforms state after the command runs |
  | `:around` | `((state -> state), state -> state)` | Receives the original execute function; full control over whether/how it runs |
  | `:override` | `(state -> state)` | Completely replaces the command; original never runs |

  Uses ETS with `read_concurrency: true` for zero-contention reads in the
  hot `dispatch_command` path. Writes only happen at config load/reload.

  ## Composition

  Multiple advice functions for the same phase and command run in
  registration order. For `:around`, they nest: the outermost advice
  wraps the next one, which wraps the next, with the original command
  at the center.

  If an `:override` is registered, it replaces the command entirely.
  Multiple overrides chain (last registered wins as the innermost).
  `:before` and `:after` still run around an overridden command.

  ## Examples

      # Transform state before save
      Minga.Config.Advice.register(:before, :save, fn state ->
        state
      end)

      # Full control: conditionally skip formatting
      Minga.Config.Advice.register(:around, :format_buffer, fn execute, state ->
        if some_condition?(state) do
          execute.(state)
        else
          Minga.Editor.State.set_status(state, "Format skipped")
        end
      end)

      # Completely replace a command
      Minga.Config.Advice.register(:override, :save, fn state ->
        my_custom_save(state)
      end)
  """

  @valid_phases [:before, :after, :around, :override]

  @table __MODULE__

  @typedoc "Advice phase."
  @type phase :: :before | :after | :around | :override

  @typedoc "Before/after/override advice: transforms editor state."
  @type state_fun :: (map() -> map())

  @typedoc "Around advice: receives the execute function and state."
  @type around_fun :: ((map() -> map()), map() -> map())

  # ── Lifecycle ───────────────────────────────────────────────────────────────

  @doc "Starts the process that owns the ETS table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__.Server, opts, name: name)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc """
  Registers an advice function for a command.

  For `:before`, `:after`, and `:override`, the function has arity 1
  (receives state, returns state). For `:around`, the function has
  arity 2 (receives the execute function and state, returns state).

  Returns `:ok` or `{:error, reason}` if the phase is invalid.
  """
  @spec register(phase(), atom(), function()) :: :ok | {:error, String.t()}
  def register(phase, command, fun) when is_atom(phase) and is_atom(command),
    do: register(@table, phase, command, fun)

  @spec register(atom(), phase(), atom(), function()) :: :ok | {:error, String.t()}
  def register(table, phase, command, fun)
      when is_atom(table) and is_atom(phase) and is_atom(command) do
    cond do
      phase not in @valid_phases ->
        {:error,
         "invalid advice phase: #{inspect(phase)}. Valid phases: #{inspect(@valid_phases)}"}

      phase == :around and not is_function(fun, 2) ->
        {:error, ":around advice must be a 2-arity function (fn execute, state -> state end)"}

      phase != :around and not is_function(fun, 1) ->
        {:error, ":#{phase} advice must be a 1-arity function (fn state -> state end)"}

      true ->
        key = {phase, command}

        existing =
          case :ets.lookup(table, key) do
            [{^key, funs}] -> funs
            [] -> []
          end

        :ets.insert(table, {key, [fun | existing]})
        :ok
    end
  end

  @doc """
  Wraps a command's execute function with all registered advice.

  Returns a function `(state -> state)` that applies before advice,
  then the (possibly around-wrapped or overridden) command, then
  after advice.

  This is the main integration point called by `dispatch_command`.
  """
  @spec wrap(atom(), (map() -> map())) :: (map() -> map())
  def wrap(command, execute) when is_atom(command) and is_function(execute, 1),
    do: wrap(@table, command, execute)

  @spec wrap(atom(), atom(), (map() -> map())) :: (map() -> map())
  def wrap(table, command, execute)
      when is_atom(table) and is_atom(command) and is_function(execute, 1) do
    befores = lookup_funs(table, :before, command)
    afters = lookup_funs(table, :after, command)
    arounds = lookup_funs(table, :around, command)
    overrides = lookup_funs(table, :override, command)

    # If no advice at all, return the original function unchanged
    if befores == [] and afters == [] and arounds == [] and overrides == [] do
      execute
    else
      core = build_core(execute, overrides, arounds)

      fn state ->
        state
        |> run_chain(befores, :before, command)
        |> run_core(core, command)
        |> run_chain(afters, :after, command)
      end
    end
  end

  @doc """
  Returns true if any advice is registered for the given phase and command.
  """
  @spec has_advice?(phase(), atom()) :: boolean()
  def has_advice?(phase, command), do: has_advice?(@table, phase, command)

  @spec has_advice?(atom(), phase(), atom()) :: boolean()
  def has_advice?(table, phase, command) do
    case :ets.lookup(table, {phase, command}) do
      [{_, [_ | _]}] -> true
      _ -> false
    end
  end

  @doc "Returns true if any advice of any phase is registered for the command."
  @spec advised?(atom()) :: boolean()
  def advised?(command), do: advised?(@table, command)

  @spec advised?(atom(), atom()) :: boolean()
  def advised?(table, command) do
    Enum.any?(@valid_phases, &has_advice?(table, &1, command))
  end

  @doc "Removes all registered advice."
  @spec reset() :: :ok
  def reset, do: reset(@table)

  @spec reset(atom()) :: :ok
  def reset(table) do
    :ets.delete_all_objects(table)
    :ok
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec lookup_funs(atom(), phase(), atom()) :: [function()]
  defp lookup_funs(table, phase, command) do
    case :ets.lookup(table, {phase, command}) do
      [{_, funs}] -> Enum.reverse(funs)
      [] -> []
    end
  end

  # Builds the core function: override replaces execute, around wraps it.
  # If both are present, arounds wrap the override.
  @spec build_core((map() -> map()), [state_fun()], [around_fun()]) :: (map() -> map())
  defp build_core(execute, [], []), do: execute

  defp build_core(_execute, overrides, []) do
    # Last override wins (innermost)
    List.last(overrides)
  end

  defp build_core(execute, overrides, arounds) do
    base =
      case overrides do
        [] -> execute
        _ -> List.last(overrides)
      end

    # Arounds nest: first registered is outermost
    Enum.reduce(Enum.reverse(arounds), base, fn around_fn, inner ->
      fn state -> around_fn.(inner, state) end
    end)
  end

  @spec run_chain(map(), [state_fun()], phase(), atom()) :: map()
  defp run_chain(state, [], _phase, _command), do: state

  defp run_chain(state, funs, phase, command) do
    Enum.reduce(funs, state, fn fun, acc ->
      try do
        fun.(acc)
      rescue
        e ->
          Minga.Log.warning(:config, "Advice #{phase}:#{command} failed: #{Exception.message(e)}")
          acc
      catch
        kind, reason ->
          Minga.Log.warning(
            :config,
            "Advice #{phase}:#{command} crashed: #{inspect(kind)} #{inspect(reason)}"
          )

          acc
      end
    end)
  end

  @spec run_core(map(), (map() -> map()), atom()) :: map()
  defp run_core(state, core, command) do
    core.(state)
  rescue
    e ->
      Minga.Log.warning(:config, "Advice core for #{command} failed: #{Exception.message(e)}")
      state
  catch
    kind, reason ->
      Minga.Log.warning(
        :config,
        "Advice core for #{command} crashed: #{inspect(kind)} #{inspect(reason)}"
      )

      state
  end

  # ── Internal GenServer (table owner) ────────────────────────────────────────

  defmodule Server do
    @moduledoc false
    use GenServer

    @impl true
    @spec init(keyword()) :: {:ok, atom()}
    def init(opts) do
      table = Keyword.get(opts, :name, Minga.Config.Advice)

      :ets.new(table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true
      ])

      {:ok, table}
    end
  end
end
