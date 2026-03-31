defmodule Minga.Command.Provider do
  @moduledoc """
  Behaviour for modules that provide editor commands.

  Any module implementing this behaviour declares the commands it provides
  via `__commands__/0`. The `Minga.Command.Registry` aggregates commands
  from all provider modules at startup.

  Adding a new command means adding one entry in the sub-module that
  implements it. Zero changes to the Registry or dispatcher.

  Extensions can also register commands at runtime via
  `Minga.Command.Registry.register/4` without implementing this behaviour.
  Both paths write to the same ETS table and are immediately dispatchable.

  ## Example

      defmodule MingaEditor.Commands.MyFeature do
        @behaviour Minga.Command.Provider

        alias Minga.Command

        @impl true
        def __commands__ do
          [
            %Command{
              name: :my_command,
              description: "Does something cool",
              requires_buffer: true,
              execute: fn state -> do_something(state) end
            }
          ]
        end

        defp do_something(state), do: state
      end
  """

  @doc """
  Returns the list of commands this module provides.

  Each command is a `Minga.Command.t()` struct with name, description,
  execute function, requires_buffer flag, and optional scope.
  """
  @callback __commands__() :: [Minga.Command.t()]
end
