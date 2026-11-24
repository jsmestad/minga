defmodule Minga.Test.PrivateLanguageRegistry do
  @moduledoc """
  Starts an isolated `Minga.Language.Registry` for one test.

  The registry gets a unique process name and a unique ETS table, so a test can register languages and overrides without touching the application registry. Pass the returned table to every `Minga.Language.Registry` and `Minga.Language.Filetype` call.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Minga.Language.Registry

  @doc "Starts a private registry under the test supervisor and returns its table name."
  @spec start!() :: Registry.table()
  def start! do
    unique = System.unique_integer([:positive])
    table = :"minga_language_registry_test_#{unique}"
    name = :"Minga.Language.Registry.Test#{unique}"

    start_supervised!(%{
      id: {Registry, table},
      start: {Registry, :start_link, [[name: name, table: table]]}
    })

    table
  end
end
