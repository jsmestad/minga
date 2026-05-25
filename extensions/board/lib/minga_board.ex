defmodule MingaBoard do
  @moduledoc """
  Bundled Board shell extension for Minga.

  Core keeps the generic shell registry, dispatch, and Traditional fallback. This extension owns the Board shell implementation, input handlers, persistence, agent card lifecycle, and typed GUI payload production.
  """

  use Minga.Extension

  command(:toggle_board, "Toggle The Board view",
    requires_buffer: false,
    execute: {MingaBoard.Commands, :toggle}
  )

  keybind(:normal, "SPC t b", :toggle_board, "Toggle The Board")

  @impl true
  def name, do: :minga_board

  @impl true
  def description, do: "Board shell"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def init(_config) do
    :ok = MingaBoard.Feature.register_contributions()
    {:ok, %{}}
  end
end
