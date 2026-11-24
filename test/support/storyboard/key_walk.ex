defmodule Minga.Test.Storyboard.KeyWalk do
  @moduledoc """
  A random walk over the keys of the active trie, for the storyboard's property test.

  `alphabet/1` reads the keys available in a frame from the keymap: the children of the open which-key node (a group child is followed by a pause, so which-key opens on it), or the Vim normal keys and `SPC (pause)` at rest, plus `esc` everywhere. Anywhere else (a prompt, a picker, Insert mode) the walk can type a letter or press `esc`. Leader commands in `Minga.Test.Storyboard.Explorer.skipped_commands/0`, and commands with a known violation the explorer already tracks (`Minga.Test.Storyboard.KnownViolations`), are left out.

  A walk is a list of choices; `step/2` turns a choice into a key for the current frame, so the same choices always replay the same walk.
  """

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Defaults
  alias Minga.Test.Storyboard.Explorer
  alias Minga.Test.Storyboard.Keys
  alias Minga.Test.Storyboard.KnownViolations
  alias Minga.Test.Storyboard.Model
  alias Minga.Test.Storyboard.Session

  @doc "The keys the walk may press in this frame, in inventory notation."
  @spec alphabet(Model.t()) :: [String.t()]
  def alphabet(%Model{which_key: %{prefix: prefix}}) do
    case node_at(prefix) do
      nil -> ["esc"]
      node -> ["esc" | which_key_keys(node)]
    end
  end

  def alphabet(%Model{mode: :normal} = model) do
    if Model.transient_open?(model),
      do: ["esc", "j"],
      else: ["esc", "SPC (pause)" | normal_keys()]
  end

  def alphabet(%Model{}), do: ["esc", "x"]

  @doc "Presses the key the choice picks from the current frame's alphabet; returns the session and the key."
  @spec step(Session.t(), non_neg_integer()) :: {Session.t(), String.t()}
  def step(session, choice) do
    keys = session |> Session.model() |> alphabet()
    key = Enum.at(keys, rem(choice, length(keys)))
    {Session.press(session, key), key}
  end

  @spec normal_keys() :: [String.t()]
  defp normal_keys do
    for %{scope: :editor, state: :normal, origin: :effective, keys: [{codepoint, mods} | _]} <-
          Minga.Test.KeyGrammar.inventory(),
        uniq: true,
        do: Keys.format([{:key, codepoint, mods}])
  end

  @spec which_key_keys(Bindings.node_t()) :: [String.t()]
  defp which_key_keys(node) do
    skipped = Explorer.skipped_commands()
    known = KnownViolations.commands()

    for {key, _label} <- Bindings.children(node),
        target = Bindings.lookup(node, key),
        not left_out?(target, skipped, known) do
      notation = Keys.format([{:key, elem(key, 0), elem(key, 1)}])
      if match?({:prefix, _}, target), do: notation <> " (pause)", else: notation
    end
  end

  @spec left_out?(term(), map(), [String.t()]) :: boolean()
  defp left_out?({:command, command}, skipped, known),
    do: Map.has_key?(skipped, command) or inspect(command) in known

  defp left_out?(_target, _skipped, _known), do: false

  @spec node_at(String.t()) :: Bindings.node_t() | nil
  defp node_at(prefix) do
    case prefix |> Keys.parse!() |> tl() do
      [] -> Defaults.leader_trie()
      rest -> descend(Defaults.leader_trie(), rest)
    end
  end

  @spec descend(Bindings.node_t(), [Keys.step()]) :: Bindings.node_t() | nil
  defp descend(node, []), do: node

  defp descend(node, [{:key, codepoint, mods} | rest]) do
    case Bindings.lookup(node, {codepoint, mods}) do
      {:prefix, child} -> descend(child, rest)
      _other -> nil
    end
  end
end
