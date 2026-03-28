defmodule Minga.Keymap.Scope.Builder do
  @moduledoc """
  Declarative builder for keymap scope modules.

  Reduces boilerplate in scope modules and ensures shared binding groups
  are correctly merged into per-vim-state tries at compile time. Each scope
  module `use`s this builder and gets:

  - Automatic `@behaviour Minga.Keymap.Scope` implementation
  - Default `name/0`, `display_name/0`, `on_enter/1`, `on_exit/1` callbacks
  - `build_trie/1` helper for declarative group merging + scope-specific bindings
  - `groups_to_trie/1` for building a trie from groups alone (no scope bindings)

  ## Usage

      defmodule Minga.Keymap.Scope.MyScope do
        use Minga.Keymap.Scope.Builder,
          name: :my_scope,
          display_name: "My Scope"

        @impl true
        def keymap(:normal, _context) do
          build_trie(
            groups: [:cua_navigation, {:cua_cmd_chords, exclude: [:select_all]}],
            exclude: [:quit_editor],
            then: fn trie ->
              trie
              |> Bindings.bind([{?q, 0}], :my_close, "Close")
            end
          )
        end
        def keymap(_state, _context), do: Bindings.new()
      end

  ## Group merging order

  Groups are merged first (in declaration order), then the `then` function
  runs on top. This means scope-specific bindings in `then` override group
  bindings on conflict. Per-group exclusions (via `{name, exclude: [...]}`)
  are applied when merging that specific group. Global exclusions (via the
  top-level `exclude:` option) apply to all groups.

  ## Compile-time evaluation

  The trie is built when the `defp` function is first called (BEAM memoizes
  the pattern match). There's no per-keystroke overhead. To force compile-time
  evaluation, assign the result to a module attribute:

      @my_trie build_trie(groups: [:cua_navigation])
  """

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.SharedGroups

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Minga.Keymap.Scope
      import Minga.Keymap.Scope.Builder, only: [build_trie: 1, groups_to_trie: 1]

      @_scope_name Keyword.fetch!(opts, :name)
      @_scope_display_name Keyword.fetch!(opts, :display_name)

      @impl true
      @spec name() :: atom()
      def name, do: @_scope_name

      @impl true
      @spec display_name() :: String.t()
      def display_name, do: @_scope_display_name

      @impl true
      @spec on_enter(term()) :: term()
      def on_enter(state), do: state

      @impl true
      @spec on_exit(term()) :: term()
      def on_exit(state), do: state

      defoverridable on_enter: 1, on_exit: 1
    end
  end

  @doc """
  Builds a trie by merging shared groups, then applying scope-specific bindings.

  ## Options

  - `:groups` - list of group names or `{name, opts}` tuples to merge. Groups
    are merged in order; later groups override earlier ones on key conflict.
  - `:exclude` - list of command atoms to exclude from ALL groups. Applied
    globally before per-group exclusions.
  - `:then` - function `(trie -> trie)` that applies scope-specific bindings
    on top of the merged groups. Runs last, so scope bindings win on conflict.

  ## Examples

      # Groups only
      build_trie(groups: [:cua_navigation, :cua_cmd_chords])

      # Groups with global exclusion
      build_trie(groups: [:cua_navigation], exclude: [:move_up])

      # Groups with per-group exclusion
      build_trie(groups: [{:cua_navigation, exclude: [:half_page_up]}])

      # Groups + scope-specific bindings
      build_trie(
        groups: [:ctrl_agent_common],
        then: fn trie ->
          trie
          |> Bindings.bind([{27, 0}], :my_escape, "Escape")
        end
      )
  """
  @spec build_trie(keyword()) :: Bindings.node_t()
  def build_trie(opts) when is_list(opts) do
    groups = Keyword.get(opts, :groups, [])
    global_excludes = Keyword.get(opts, :exclude, [])
    then_fn = Keyword.get(opts, :then, fn trie -> trie end)

    Bindings.new()
    |> merge_groups(groups, global_excludes)
    |> then_fn.()
  end

  @doc """
  Builds a trie from shared groups only, with no scope-specific bindings.

  Shorthand for `build_trie(groups: groups)`.
  """
  @spec groups_to_trie([atom() | {atom(), keyword()}]) :: Bindings.node_t()
  def groups_to_trie(groups) when is_list(groups) do
    build_trie(groups: groups)
  end

  @doc """
  Returns the list of group names from a group spec list.

  Normalizes `{name, opts}` tuples to just the name atom. Useful for
  implementing `included_groups/0`.
  """
  @spec group_names_from([atom() | {atom(), keyword()}]) :: [atom()]
  def group_names_from(groups) when is_list(groups) do
    Enum.map(groups, fn
      {name, _opts} when is_atom(name) -> name
      name when is_atom(name) -> name
    end)
  end

  @doc """
  Validates that all group names in a spec list exist in SharedGroups.

  Returns `:ok` or raises `ArgumentError` with the unknown group names.
  Useful as a compile-time check in scope modules.
  """
  @spec validate_groups!([atom() | {atom(), keyword()}]) :: :ok
  def validate_groups!(groups) when is_list(groups) do
    known = MapSet.new(SharedGroups.group_names())

    unknown =
      groups
      |> group_names_from()
      |> Enum.reject(&MapSet.member?(known, &1))

    case unknown do
      [] -> :ok
      names -> raise ArgumentError, "unknown shared groups: #{inspect(names)}"
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  @spec merge_groups(Bindings.node_t(), [atom() | {atom(), keyword()}], [atom()]) ::
          Bindings.node_t()
  defp merge_groups(trie, groups, global_excludes) do
    Enum.reduce(groups, trie, fn group_spec, acc ->
      {name, per_group_opts} = normalize_group_spec(group_spec)
      per_group_excludes = Keyword.get(per_group_opts, :exclude, [])
      all_excludes = Enum.uniq(global_excludes ++ per_group_excludes)

      if all_excludes == [] do
        Bindings.merge_group(acc, name)
      else
        Bindings.merge_group(acc, name, exclude: all_excludes)
      end
    end)
  end

  @spec normalize_group_spec(atom() | {atom(), keyword()}) :: {atom(), keyword()}
  defp normalize_group_spec({name, opts}) when is_atom(name) and is_list(opts), do: {name, opts}
  defp normalize_group_spec(name) when is_atom(name), do: {name, []}
end
