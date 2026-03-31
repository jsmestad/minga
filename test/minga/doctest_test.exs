defmodule Minga.DoctestTest do
  @moduledoc """
  Runs ExUnit doctests for all modules that carry `iex>` examples in their
  `@moduledoc` / `@doc` attributes.

  Adding a `doctest` call here is sufficient — ExUnit discovers every
  `iex>` block in the named module and turns it into a test case.
  """

  use ExUnit.Case, async: true

  doctest Minga.Buffer.Document
  doctest Minga.Editing.Motion
  doctest Minga.Keymap.Bindings
  doctest MingaEditor.UI.WhichKey
  doctest Minga.Command.Parser
end
