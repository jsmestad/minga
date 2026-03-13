defmodule Minga.Popup.Registry do
  @moduledoc """
  ETS-backed registry of popup rules.

  Rules are stored in a named ETS table and looked up when a buffer is
  opened. The registry is ordered by priority (higher priority wins) and
  insertion order as tiebreaker (later registrations win).

  The table uses `read_concurrency: true` because rule lookups happen on
  every buffer open, while registrations only happen at startup and when
  the user reloads config.

  ## Usage

      Popup.Registry.register(Popup.Rule.new("*Warnings*", side: :bottom))
      Popup.Registry.match("*Warnings*")
      #=> {:ok, %Popup.Rule{pattern: "*Warnings*", ...}}

      Popup.Registry.match("some-file.ex")
      #=> :none
  """

  alias Minga.Popup.Rule

  @table __MODULE__

  @doc """
  Creates the ETS table. Called once during application startup.

  Safe to call multiple times; returns `:already_exists` if the table
  already exists.
  """
  @spec init() :: :ok | :already_exists
  def init do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :ordered_set,
          :public,
          read_concurrency: true
        ])

        :ok

      _ref ->
        :already_exists
    end
  end

  @doc """
  Registers a popup rule.

  If a rule with the same pattern already exists, it is replaced. The key
  is `{-priority, sequence}` so that higher priority rules sort first, with
  later registrations winning ties.
  """
  @spec register(Rule.t()) :: :ok
  def register(%Rule{} = rule) do
    ensure_table!()
    seq = next_sequence()
    key = {-rule.priority, seq}
    :ets.insert(@table, {key, rule})
    :ok
  end

  @doc """
  Finds the highest-priority rule matching the given buffer name.

  Walks rules in priority order (highest first, with later registrations
  winning ties at the same priority). Returns `{:ok, rule}` for the first
  match, or `:none` if no rule matches.
  """
  @spec match(String.t()) :: {:ok, Rule.t()} | :none
  def match(buffer_name) when is_binary(buffer_name) do
    ensure_table!()
    find_match(:ets.first(@table), buffer_name)
  end

  @doc """
  Returns all registered rules, ordered by priority (highest first).
  """
  @spec list() :: [Rule.t()]
  def list do
    ensure_table!()

    :ets.tab2list(@table)
    |> Enum.map(fn {_key, rule} -> rule end)
  end

  @doc """
  Removes all rules matching the given pattern.

  Used when user config overrides a built-in rule: the old rule is
  cleared before the new one is registered.
  """
  @spec unregister(Regex.t() | String.t()) :: :ok
  def unregister(pattern) do
    ensure_table!()

    :ets.tab2list(@table)
    |> Enum.each(fn {key, rule} ->
      if patterns_equal?(rule.pattern, pattern) do
        :ets.delete(@table, key)
      end
    end)

    :ok
  end

  @doc """
  Removes all registered rules. Used during config reload.
  """
  @spec clear() :: :ok
  def clear do
    ensure_table!()
    :ets.delete_all_objects(@table)
    :ok
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec find_match(term(), String.t()) :: {:ok, Rule.t()} | :none
  defp find_match(:"$end_of_table", _buffer_name), do: :none

  defp find_match(key, buffer_name) do
    case :ets.lookup(@table, key) do
      [{_key, rule}] ->
        if Rule.matches?(rule, buffer_name) do
          {:ok, rule}
        else
          find_match(:ets.next(@table, key), buffer_name)
        end

      [] ->
        find_match(:ets.next(@table, key), buffer_name)
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

  @spec ensure_table!() :: :ok
  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined -> init()
      _ref -> :ok
    end

    :ok
  end
end
