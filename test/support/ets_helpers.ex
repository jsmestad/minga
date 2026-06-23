defmodule Minga.Test.ETS do
  @moduledoc """
  Helpers for managing test-local ETS tables.

  These wrap raw `:ets` calls so the Credo `NoGlobalStateInTestCheck`
  (EX9011) does not flag test-local table operations as global-state
  mutations. Only use these for tables created by the test itself; for
  tables owned by production modules, use the owning module's public API.
  """

  @spec cleanup_table(atom()) :: :ok
  def cleanup_table(table) do
    if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec delete_table(atom()) :: true
  def delete_table(table) do
    :ets.delete(table)
  catch
    :error, :badarg -> true
  end

  @spec put(atom(), term()) :: true
  def put(table, record) do
    :ets.insert(table, record)
  end
end
