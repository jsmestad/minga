defmodule Minga.Popup.Registry do
  @moduledoc """
  ETS-backed registry of popup rules.

  Rules are stored in a named ETS table and looked up when a buffer is
  opened. The registry is ordered by priority (higher priority wins) and
  insertion order as tiebreaker (later registrations win).

  The table uses `read_concurrency: true` because rule lookups happen on
  every buffer open, while registrations only happen at startup and when
  the user reloads config.

  Every public function has a default-arg version that uses the global
  `@table` and an explicit-table version for tests that create private
  instances. This follows the same pattern as `Minga.Config.Advice`.

  ## Usage

      Minga.Popup.Registry.register(Minga.Popup.Rule.new("*Warnings*", side: :bottom))
      Minga.Popup.Registry.match("*Warnings*")
      #=> {:ok, %Popup.Rule{pattern: "*Warnings*", ...}}

      Popup.Registry.match("*Messages*")
      #=> :none

  ## Test usage (private instance)

      table = Minga.Popup.Registry.init(:test_popup_registry)
      Minga.Popup.Registry.register(rule, table)
      assert {:ok, _} = Minga.Popup.Registry.match("*Warnings*", table)
  """

  alias Minga.Popup.Rule

  @table __MODULE__

  # ── Table lifecycle ────────────────────────────────────────────────────────

  @doc """
  Creates the ETS table. Called once during application startup.

  Accepts an optional table name for testing. Returns the table name.
  Safe to call multiple times; returns the existing table if it exists.
  """
  @spec init() :: atom()
  @spec init(atom()) :: atom()
  def init, do: init(@table)

  def init(table_name) when is_atom(table_name) do
    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [
          :named_table,
          :ordered_set,
          :public,
          read_concurrency: true
        ])

      _ref ->
        :ok
    end

    table_name
  end

  # ── Register / unregister ──────────────────────────────────────────────────

  @doc """
  Registers a popup rule.

  If a rule with the same pattern already exists, it is replaced. The key
  is `{-priority, sequence}` so that higher priority rules sort first, with
  later registrations winning ties.
  """
  @spec register(Rule.t()) :: :ok
  @spec register(Rule.t(), atom()) :: :ok
  def register(rule), do: register(rule, @table)

  def register(%Rule{} = rule, table) do
    ensure_table!(table)
    seq = next_sequence()
    key = {-rule.priority, seq}
    :ets.insert(table, {key, rule})
    :ok
  end

  @doc """
  Removes all rules matching the given pattern.

  Used when user config overrides a built-in rule: the old rule is
  cleared before the new one is registered.
  """
  @spec unregister(Regex.t() | String.t()) :: :ok
  @spec unregister(Regex.t() | String.t(), atom()) :: :ok
  def unregister(pattern), do: unregister(pattern, @table)

  def unregister(pattern, table) do
    ensure_table!(table)

    :ets.tab2list(table)
    |> Enum.each(fn {key, rule} ->
      if patterns_equal?(rule.pattern, pattern) do
        :ets.delete(table, key)
      end
    end)

    :ok
  end

  @doc """
  Removes all registered rules. Used during config reload.
  """
  @spec clear() :: :ok
  @spec clear(atom()) :: :ok
  def clear, do: clear(@table)

  def clear(table) do
    ensure_table!(table)
    :ets.delete_all_objects(table)
    :ok
  end

  # ── Lookup ─────────────────────────────────────────────────────────────────

  @doc """
  Finds the highest-priority rule matching the given buffer name.

  Walks rules in priority order (highest first, with later registrations
  winning ties at the same priority). Returns `{:ok, rule}` for the first
  match, or `:none` if no rule matches.
  """
  @spec match(String.t()) :: {:ok, Rule.t()} | :none
  @spec match(String.t(), atom()) :: {:ok, Rule.t()} | :none
  def match(buffer_name), do: match(buffer_name, @table)

  def match(buffer_name, table) when is_binary(buffer_name) do
    ensure_table!(table)
    find_match(:ets.first(table), buffer_name, table)
  end

  @doc """
  Returns all registered rules, ordered by priority (highest first).
  """
  @spec list() :: [Rule.t()]
  @spec list(atom()) :: [Rule.t()]
  def list, do: list(@table)

  def list(table) do
    ensure_table!(table)

    :ets.tab2list(table)
    |> Enum.map(fn {_key, rule} -> rule end)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec find_match(term(), String.t(), atom()) :: {:ok, Rule.t()} | :none
  defp find_match(:"$end_of_table", _buffer_name, _table), do: :none

  defp find_match(key, buffer_name, table) do
    case :ets.lookup(table, key) do
      [{_key, rule}] ->
        if Rule.matches?(rule, buffer_name) do
          {:ok, rule}
        else
          find_match(:ets.next(table, key), buffer_name, table)
        end

      [] ->
        find_match(:ets.next(table, key), buffer_name, table)
    end
  end

  @spec next_sequence() :: integer()
  defp next_sequence do
    :erlang.unique_integer([:monotonic])
  end

  @spec patterns_equal?(Regex.t() | String.t(), Regex.t() | String.t()) :: boolean()
  defp patterns_equal?(a, b) when is_binary(a) and is_binary(b), do: a == b

  defp patterns_equal?(%Regex{source: a}, %Regex{source: b}), do: a == b

  defp patterns_equal?(_a, _b), do: false

  @spec ensure_table!(atom()) :: :ok
  defp ensure_table!(table) do
    case :ets.whereis(table) do
      :undefined -> init(table)
      _ref -> :ok
    end

    :ok
  end
end
