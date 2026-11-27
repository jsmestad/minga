defmodule Minga.Test.Storyboard.Explorer do
  @moduledoc """
  The flow explorer: presses every available key from a built scenario in the real editor and classifies where it lands.

  The keys come from the keymap, never from a hand-written list, so they follow key moves (#4028):

  * from a scenario with `explore: :normal`, every Vim normal binding and every leader binding (`edges/1` presses each full sequence from a fresh editor);
  * from a scenario with `explore: :which_key`, every child of the which-key node the scenario opens, read from the leader trie;
  * the exit table from `docs/design/scenarios.toml` adds the scenario's designed exits.

  Each press starts from a fresh editor driven to the scenario, so one key never leaks into the next. After the press the explorer records the scenario the frame classifies as (or `:unknown` with the frame's signature), then checks the way out: at most three presses of `esc`, or failing that of `q`, must reach a resting view (a `home = true` scenario: plain editing or the project home) with focus back in the window the press started from.

  A handful of leader commands leave the editor's sandbox (quit, spawn test runs, formatters or language servers, touch the global project list or extensions) or block the Editor for seconds (#4101). `skipped_commands/0` lists them with the reason; the explorer reports them as skipped, never as passing.
  """

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Defaults
  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Inventory
  alias Minga.Test.Storyboard.Keys
  alias Minga.Test.Storyboard.Model
  alias Minga.Test.Storyboard.Registry
  alias Minga.Test.Storyboard.Session

  @skipped %{
    quit_all: "quits the editor",
    reload_config: "reloads the global config for every editor",
    extension_update: "fetches extensions over the network",
    extension_update_all: "fetches extensions over the network",
    test_all: "spawns the project's test runner",
    test_file: "spawns the project's test runner",
    test_at_point: "spawns the project's test runner",
    test_rerun: "spawns the project's test runner",
    lsp_start: "spawns a language server",
    lsp_restart: "spawns a language server",
    project_add: "writes the global known-projects list",
    project_remove: "writes the global known-projects list",
    project_invalidate: "clears the global project cache",
    format_buffer: "spawns the external formatter (mix format)",
    describe_function:
      "blocks the Editor while it loads every module and writes :persistent_term (#4101)"
  }

  @typedoc "Where one key path from a scenario lands."
  @type edge :: %{
          from: String.t(),
          keys: String.t(),
          command: term(),
          to: String.t() | :unknown | :crashed | :skipped,
          signature: String.t(),
          changed?: boolean(),
          silent_errors: [String.t()],
          way_out: :ok | {:stranded, String.t()} | :not_checked
        }

  @typedoc "One key path to press, with the command the keymap binds it to (nil for a prefix or a designed exit)."
  @type probe :: {String.t(), term()}

  @doc "Commands the explorer does not run, with the reason."
  @spec skipped_commands() :: %{atom() => String.t()}
  def skipped_commands, do: @skipped

  @doc "Every key path the explorer presses from the scenario: keymap bindings plus designed exits."
  @spec probes(Entry.t()) :: [probe()]
  def probes(%Entry{} = entry) do
    (keymap_probes(entry) ++ exit_probes(entry))
    |> Enum.uniq_by(fn {keys, _command} -> keys end)
  end

  @doc "Presses every probe from the scenario and returns where each one lands."
  @spec edges(Entry.t()) :: [edge()]
  def edges(%Entry{} = entry) do
    baseline = baseline(entry)
    Enum.map(probes(entry), &edge(entry, &1, baseline))
  end

  @doc """
  Presses one key path from the scenario and records the edge.

  `baseline` is the scenario's frame before the press (`changed?` compares against it); it defaults to a fresh one.
  """
  @spec edge(Entry.t(), probe(), Model.t() | nil) :: edge()
  def edge(%Entry{id: id} = entry, {keys, command}, baseline \\ nil) do
    base = %{
      from: id,
      keys: keys,
      command: command,
      to: :skipped,
      signature: "",
      changed?: false,
      silent_errors: [],
      way_out: :not_checked
    }

    if is_atom(command) and Map.has_key?(@skipped, command) do
      %{base | to: :skipped, signature: Map.fetch!(@skipped, command)}
    else
      press_edge(entry, keys, base, baseline || baseline(entry))
    end
  end

  @doc """
  Checks the way out from the session's current state: at most three presses return to a resting view with focus in the starting window. Escape can leave an input field before `q` closes its surface.

  `replay` rebuilds the same state for each alternative, since an attempt consumes it; the replayed sessions are stopped afterwards. The caller owns `session`, and may pass its current `model` to save building it again.
  """
  @spec way_out(Session.t(), (-> Session.t()), Model.t() | nil) :: :ok | {:stranded, String.t()}
  def way_out(%Session{} = session, replay, model \\ nil) when is_function(replay, 0) do
    model = model || Session.model(session)

    with {:error, by_esc} <- escape(session, "esc", 3, model),
         {:error, by_q} <- with_session(replay, &escape(&1, "q", 3)) do
      case model do
        %Model{ui: %{subagent_peek: %{pane: %{editing?: true}}}} ->
          with_session(replay, fn fresh ->
            case fresh |> Session.press("esc") |> escape("q", 2) do
              :ok -> :ok
              {:error, signature} -> {:stranded, "esc q q left #{signature}"}
            end
          end)

        %Model{} ->
          {:stranded, "esc ×3 left #{by_esc}; q ×3 left #{by_q}"}
      end
    end
  end

  @doc "Runs `fun` on a fresh session from `start`, then stops that session."
  @spec with_session((-> Session.t()), (Session.t() -> result)) :: result when result: term()
  def with_session(start, fun) when is_function(start, 0) and is_function(fun, 1) do
    session = start.()

    try do
      fun.(session)
    after
      Session.stop(session)
    end
  end

  @spec baseline(Entry.t()) :: Model.t()
  defp baseline(entry), do: with_session(fn -> Registry.drive(entry) end, &Session.model/1)

  @spec press_edge(Entry.t(), String.t(), map(), Model.t()) :: edge()
  defp press_edge(entry, keys, base, baseline) do
    replay = fn -> entry |> Registry.drive() |> Session.press(keys) end

    with_session(fn -> Registry.drive(entry) end, fn session ->
      session = Session.press(session, keys)
      model = Session.model(session)

      Map.merge(base, %{
        changed?: baseline.ui != model.ui,
        silent_errors: silent_errors(model),
        to: Registry.classify(model),
        signature: Model.signature(model),
        way_out: way_out(session, replay, model)
      })
    end)
  rescue
    error -> Map.merge(base, %{to: :crashed, signature: Exception.message(error)})
  catch
    :exit, reason -> Map.merge(base, %{to: :crashed, signature: Exception.format_exit(reason)})
  end

  @spec silent_errors(Model.t()) :: [String.t()]
  defp silent_errors(%Model{ui: %{notifications: %{items: items}}}),
    do: for(%{level: :error, actions: [], title: title} <- items, do: title)

  defp silent_errors(%Model{}), do: []

  @spec escape(Session.t(), String.t(), non_neg_integer(), Model.t() | nil) ::
          :ok | {:error, String.t()}
  defp escape(session, key, presses, model \\ nil) do
    model = model || Session.model(session)

    cond do
      home?(session, model) -> :ok
      presses == 0 -> {:error, Model.signature(model)}
      true -> session |> Session.press(key) |> escape(key, presses - 1)
    end
  end

  @spec home?(Session.t(), Model.t()) :: boolean()
  defp home?(session, model) do
    Registry.resting?(Registry.classify(model)) and
      match?(%{window_id: window} when window == session.home_window, model.focus)
  end

  @spec keymap_probes(Entry.t()) :: [probe()]
  defp keymap_probes(%Entry{explore: :normal}) do
    normal =
      for {keys, command} <- normal_bindings(), do: {format(keys), command}

    leader =
      for {keys, command} <- leader_bindings(Defaults.leader_trie(), [{32, 0}]),
          do: {format(keys), command}

    [{"SPC (pause)", nil} | normal ++ leader]
  end

  defp keymap_probes(%Entry{explore: :which_key, reach: reach}) do
    # The leader trie is the node after SPC, so the walk starts below the first key.
    # The reach opens the file first (`1` on the home); the which-key path starts at SPC.
    [{:key, 32, 0} | prefix] =
      reach
      |> Keys.parse!()
      |> Enum.reject(&(&1 == :pause))
      |> Enum.drop_while(&(&1 != {:key, 32, 0}))

    node = Enum.reduce(prefix, Defaults.leader_trie(), &child(&2, &1))

    for {key, target} <- children(node) do
      case target do
        {:command, command} -> {format([key]), command}
        {:prefix, _node} -> {format([key]) <> " (pause)", nil}
      end
    end
  end

  defp keymap_probes(%Entry{}), do: []

  @spec exit_probes(Entry.t()) :: [probe()]
  defp exit_probes(%Entry{id: id}) do
    for exit <- id |> Inventory.fetch!() |> Inventory.exits(),
        {:ok, _steps} <- [Keys.parse(Map.get(exit, "key", ""))],
        do: {String.trim(exit["key"]), nil}
  end

  @spec normal_bindings() :: [{[Keys.step()], term()}]
  defp normal_bindings do
    for %{scope: :editor, state: :normal, origin: :effective, keys: keys, command: command} <-
          Minga.Test.KeyGrammar.inventory(),
        do: {Enum.map(keys, fn {codepoint, mods} -> {:key, codepoint, mods} end), command}
  end

  @spec leader_bindings(Bindings.node_t(), [{non_neg_integer(), non_neg_integer()}]) ::
          [{[Keys.step()], term()}]
  defp leader_bindings(node, path) do
    Enum.flat_map(children(node), fn
      {{:key, codepoint, mods}, {:command, command}} ->
        [{Enum.map(path, &to_step/1) ++ [{:key, codepoint, mods}], command}]

      {{:key, codepoint, mods}, {:prefix, child}} ->
        leader_bindings(child, path ++ [{codepoint, mods}])
    end)
  end

  @spec to_step({non_neg_integer(), non_neg_integer()}) :: Keys.step()
  defp to_step({codepoint, mods}), do: {:key, codepoint, mods}

  @spec children(Bindings.node_t()) :: [
          {Keys.step(), {:command, term()} | {:prefix, Bindings.node_t()}}
        ]
  defp children(node) do
    for {{codepoint, mods} = key, _label, _kind} <- Bindings.children(node) do
      target =
        case Bindings.lookup(node, key) do
          {:command, command} -> {:command, command}
          {:prefix, child} -> {:prefix, child}
        end

      {{:key, codepoint, mods}, target}
    end
  end

  @spec child(Bindings.node_t(), Keys.step()) :: Bindings.node_t()
  defp child(node, {:key, codepoint, mods}) do
    {:prefix, child} = Bindings.lookup(node, {codepoint, mods})
    child
  end

  @spec format([Keys.step()]) :: String.t()
  defp format(steps), do: Keys.format(steps)
end
