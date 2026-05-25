defmodule MingaBoard.Feature do
  @moduledoc "Registers Board extension contributions."

  @source {:extension, :minga_board}

  @doc "Registers the Board shell contribution."
  @spec register_contributions() :: :ok | {:error, term()}
  def register_contributions do
    MingaEditor.Shell.Registry.register(@source, %{
      id: :board,
      module: MingaBoard.Shell,
      display_name: "Board",
      description: "Agent supervisor card view.",
      capabilities: [:gui, :tui]
    })
  end
end
