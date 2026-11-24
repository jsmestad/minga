defmodule Minga.Test.Storyboard.Assertions do
  @moduledoc """
  Design assertions over a `Minga.Test.Storyboard.Model`, by structure and token name, never by pixel.

  Each function raises `ExUnit.AssertionError` with a message that names the scenario fact that differs, and returns the model otherwise, so assertions pipe:

      model
      |> assert_surface(:which_key)
      |> assert_focus(:editor)
      |> assert_group("a", "Minga")

  The names follow `docs/design/surfaces.md`: modeline segment roles (`modeline_order/0`), which-key groups and leaves, keys shown on transient surfaces, the surface that is open and the one that has focus, and the empty-state anatomy (title, description, action list with the first action preselected).
  """

  import ExUnit.Assertions

  alias Minga.Design.Tokens
  alias Minga.Test.Storyboard.Model
  alias MingaEditor.UI.Theme

  @modeline_order [
    :mode,
    :needs_you,
    :file,
    :change,
    :git,
    :minga,
    :diagnostics,
    :filetype,
    :position
  ]

  # Today's segment names, mapped to the design's segment roles. Unmapped names keep their own name, so a segment the design does not list fails `assert_modeline_order/2`.
  @segment_roles %{
    filename: :file,
    git_branch: :git,
    git: :git,
    lines: :position,
    chars: :position
  }

  @typedoc "One action row of an empty state or notice: its key and label."
  @type action :: {key :: String.t(), label :: String.t()}

  @typedoc "Empty-state anatomy: what happened, why, and what you can do."
  @type empty_state :: %{
          title: String.t(),
          description: String.t(),
          actions: [action()],
          selected: non_neg_integer() | nil
        }

  @doc "The modeline segment roles, left to right, from `docs/design/surfaces.md`."
  @spec modeline_order() :: [atom()]
  def modeline_order, do: @modeline_order

  @doc "The modeline's segments as design roles, left to right."
  @spec modeline_roles(Model.t()) :: [atom()]
  def modeline_roles(%Model{modeline: names}),
    do: names |> Enum.map(&Map.get(@segment_roles, &1, &1)) |> Enum.dedup()

  @doc """
  Asserts the modeline shows exactly `expected` segment roles, in that order.

  `expected` must itself follow the design order; the function raises `ArgumentError` otherwise, so a scenario cannot encode an order the design forbids.
  """
  @spec assert_modeline_order(Model.t(), [atom()]) :: Model.t()
  def assert_modeline_order(%Model{} = model, expected) do
    unless expected == Enum.filter(@modeline_order, &(&1 in expected)) do
      raise ArgumentError,
            "#{inspect(expected)} does not follow the design order #{inspect(@modeline_order)}"
    end

    actual = modeline_roles(model)

    assert actual == expected,
           "modeline segments: expected #{inspect(expected)}, got #{inspect(actual)}"

    model
  end

  @doc "Asserts the surface is open in the frame."
  @spec assert_surface(Model.t(), Model.surface()) :: Model.t()
  def assert_surface(%Model{} = model, surface) do
    assert Model.open?(model, surface),
           "expected #{surface} to be open, open surfaces: #{inspect(model.surfaces)}"

    model
  end

  @doc "Asserts the surface is not open in the frame."
  @spec refute_surface(Model.t(), Model.surface()) :: Model.t()
  def refute_surface(%Model{} = model, surface) do
    refute Model.open?(model, surface),
           "expected #{surface} to be closed, open surfaces: #{inspect(model.surfaces)}"

    model
  end

  @doc "Asserts no transient surface (which-key, picker, prompt, popup) is open and no key sequence is pending."
  @spec assert_resting(Model.t()) :: Model.t()
  def assert_resting(%Model{} = model) do
    refute Model.transient_open?(model),
           "expected a resting view, open surfaces: #{inspect(model.surfaces)}"

    refute Model.key_pending?(model),
           "expected no pending key sequence, pending: #{inspect(model.pending_keys)}"

    model
  end

  @doc "Asserts which surface owns the keyboard, and optionally in which window (`window: id`)."
  @spec assert_focus(Model.t(), atom(), keyword()) :: Model.t()
  def assert_focus(%Model{focus: focus} = model, surface, opts \\ []) do
    assert focus && focus.surface == surface,
           "expected focus on #{surface}, got #{inspect(focus)}"

    case Keyword.fetch(opts, :window) do
      {:ok, window} ->
        assert focus.window_id == window,
               "expected focus in window #{window}, got window #{focus.window_id}"

      :error ->
        :ok
    end

    model
  end

  @doc "Asserts the editing mode the mode pill names."
  @spec assert_mode(Model.t(), atom()) :: Model.t()
  def assert_mode(%Model{mode: mode} = model, expected) do
    assert mode == expected, "expected mode #{expected}, got #{mode}"
    model
  end

  @doc "Asserts which-key is open on `prefix`, the breadcrumb in its border (for example `SPC` or `SPC a`)."
  @spec assert_which_key(Model.t(), String.t()) :: Model.t()
  def assert_which_key(%Model{which_key: which_key} = model, prefix) do
    assert which_key, "expected which-key on #{prefix}, which-key is closed"

    assert which_key.prefix == prefix,
           "expected which-key on #{inspect(prefix)}, got #{inspect(which_key.prefix)}"

    model
  end

  @doc """
  Asserts the which-key entry on `key` is a group labelled `label`.

  A group reads like a leaf: Title Case, no leading `+`, drawn in the `group` colour role (the semantic kind `:group`) with a trailing `›` that the builder adds (`label ›`).
  """
  @spec assert_group(Model.t(), String.t(), String.t()) :: Model.t()
  def assert_group(%Model{} = model, key, label) do
    entry = which_key_entry!(model, key)
    assert entry.kind == :group, "expected #{key} to be a group, got a #{entry.kind}"

    assert entry.label == "#{label} ›",
           "expected group #{key} to read #{inspect("#{label} ›")}, got #{inspect(entry.label)}"

    model
  end

  @doc "Asserts the which-key entry on `key` is a leaf (a command) labelled `label`."
  @spec assert_leaf(Model.t(), String.t(), String.t()) :: Model.t()
  def assert_leaf(%Model{} = model, key, label) do
    entry = which_key_entry!(model, key)
    assert entry.kind == :command, "expected #{key} to be a command, got a #{entry.kind}"

    assert entry.label == label,
           "expected #{key} to read #{inspect(label)}, got #{inspect(entry.label)}"

    model
  end

  @doc "Asserts the which-key entry on `key` carries a live count, such as `Tasks · 1 needs you`."
  @spec assert_count(Model.t(), String.t(), String.t()) :: Model.t()
  def assert_count(%Model{} = model, key, count) do
    entry = which_key_entry!(model, key)

    assert String.contains?(entry.label, " · " <> count),
           "expected #{key} to show the count #{inspect(count)}, got #{inspect(entry.label)}"

    model
  end

  @doc "Asserts every group label reads like a leaf: no leading `+`, Title Case."
  @spec assert_groups_read_like_leaves(Model.t()) :: Model.t()
  def assert_groups_read_like_leaves(%Model{which_key: %{entries: entries}} = model) do
    offenders =
      for %{kind: :group, key: key, label: label} <- entries,
          String.starts_with?(label, "+") or not title_case?(label),
          do: {key, label}

    assert offenders == [], "groups that do not read like leaves: #{inspect(offenders)}"
    model
  end

  def assert_groups_read_like_leaves(%Model{} = model) do
    flunk("expected which-key to be open, open surfaces: #{inspect(model.surfaces)}")
  end

  @doc "Asserts the open transient surface shows each of `keys` (which-key entries, or picker and prompt hints)."
  @spec assert_keys_shown(Model.t(), [String.t()]) :: Model.t()
  def assert_keys_shown(%Model{} = model, keys) do
    shown = shown_keys(model)
    missing = Enum.reject(keys, &(&1 in shown))
    assert missing == [], "keys not shown: #{inspect(missing)}, shown: #{inspect(shown)}"
    model
  end

  @doc """
  Asserts a state is spoken in the modeline the way the tokens define it: the state's word (`Minga.Design.Tokens.state_word/1`) in a segment drawn in the state's colour role (`MingaEditor.UI.Theme.state_color/2`).
  """
  @spec assert_state(Model.t(), :modeline, Tokens.state_id()) :: Model.t()
  def assert_state(%Model{} = model, :modeline, state) do
    unless state in Tokens.state_ids(),
      do: raise(ArgumentError, "unknown state token #{inspect(state)}")

    word = Tokens.state_word(state)
    segments = Model.modeline_segments(model)

    case Enum.find(segments, fn {_name, text, _fg} -> String.contains?(text, word) end) do
      nil ->
        flunk("expected the modeline to say #{inspect(word)}, segments: #{inspect(segments)}")

      {name, _text, fg} ->
        expected = Theme.state_color(theme!(model), state)

        assert fg == expected,
               "modeline #{name} says #{inspect(word)} in #{hex(fg)}, " <>
                 "expected the #{Tokens.state_role(state)} role #{hex(expected)}"
    end

    model
  end

  @doc "Asserts a modeline segment is drawn in a design-token colour role."
  @spec assert_role(Model.t(), atom(), Tokens.color_role()) :: Model.t()
  def assert_role(%Model{} = model, segment, role) do
    unless role in Tokens.color_roles(),
      do: raise(ArgumentError, "unknown colour role #{inspect(role)}")

    case List.keyfind(Model.modeline_segments(model), segment, 0) do
      nil ->
        flunk("no modeline segment #{segment} in #{inspect(model.modeline)}")

      {^segment, _text, fg} ->
        expected = Theme.role_color(theme!(model), role)

        assert fg == expected,
               "modeline #{segment} is #{hex(fg)}, expected the #{role} role #{hex(expected)}"
    end

    model
  end

  @doc "Asserts every error notification names its next step: at least one action."
  @spec assert_errors_name_next_step(Model.t()) :: Model.t()
  def assert_errors_name_next_step(%Model{ui: ui} = model) do
    items = if ui.notifications, do: ui.notifications.items, else: []

    silent =
      for %{level: :error, actions: [], title: title} <- items, do: title

    assert silent == [], "errors without a next step: #{inspect(silent)}"
    model
  end

  @doc """
  Asserts the empty-state anatomy: `title:`, `description:` and `actions:` (a list of `{key, label}`), with the first action preselected.
  """
  @spec assert_empty_state(Model.t(), keyword()) :: Model.t()
  def assert_empty_state(%Model{} = model, opts) do
    anatomy = empty_state(model)
    assert anatomy, "expected an empty state, open surfaces: #{inspect(model.surfaces)}"

    for field <- [:title, :description, :actions], Keyword.has_key?(opts, field) do
      expected = Keyword.fetch!(opts, field)
      actual = Map.fetch!(anatomy, field)

      assert actual == expected,
             "empty state #{field}: expected #{inspect(expected)}, got #{inspect(actual)}"
    end

    assert anatomy.actions != [], "an empty state must offer at least one action"

    assert anatomy.selected == 0,
           "the first action must be preselected, got #{inspect(anatomy.selected)}"

    model
  end

  @doc "The empty-state anatomy of the frame, or `nil` when none is shown."
  @spec empty_state(Model.t()) :: empty_state() | nil
  def empty_state(%Model{
        ui: %{empty_state: %{visible?: true, sections: [_ | _] = sections} = state}
      }) do
    [first | _] = sections
    items = Enum.flat_map(sections, & &1.items)
    actions = for item <- items, item.kind in [:action, :recent_file, :resume], do: item

    %{
      title: first.title,
      description: "",
      actions: Enum.map(actions, &{&1.jump_key || &1.chord, &1.label}),
      selected: Enum.find_index(actions, &(&1.id == state.focused_id))
    }
  end

  def empty_state(%Model{}), do: nil

  @spec theme!(Model.t()) :: Theme.t()
  defp theme!(%Model{theme: nil}), do: Theme.get!(Theme.default())
  defp theme!(%Model{theme: theme}), do: theme

  @spec hex(non_neg_integer()) :: String.t()
  defp hex(color), do: "#" <> String.pad_leading(Integer.to_string(color, 16), 6, "0")

  @spec which_key_entry!(Model.t(), String.t()) :: Model.which_key_entry()
  defp which_key_entry!(%Model{which_key: nil} = model, key),
    do: flunk("expected which-key to show #{key}, open surfaces: #{inspect(model.surfaces)}")

  defp which_key_entry!(%Model{which_key: %{entries: entries, prefix: prefix}}, key) do
    case Enum.find(entries, &(&1.key == key)) do
      nil ->
        flunk("which-key on #{prefix} has no #{key}: #{inspect(Enum.map(entries, & &1.key))}")

      entry ->
        entry
    end
  end

  @spec shown_keys(Model.t()) :: [String.t()]
  defp shown_keys(%Model{which_key: %{entries: entries}}), do: Enum.map(entries, & &1.key)
  defp shown_keys(%Model{}), do: []

  @spec title_case?(String.t()) :: boolean()
  defp title_case?(label) do
    case String.first(label) do
      nil -> false
      first -> first == String.upcase(first)
    end
  end
end
