defmodule Minga.Extensions.Dired do
  @moduledoc """
  Bundled UI extension for Oil.nvim-style directory editing.

  Registers Dired commands, keymap scope, and input handler through the
  source-owned contribution paths. When disabled, the editor boots without
  Dired functionality and directory paths render as plain buffers.
  """

  use Minga.Extension

  alias Minga.Extensions.Dired.Commands
  alias Minga.Extensions.Dired.Input
  alias Minga.Extensions.Dired.KeymapScope

  keybind(:normal, "SPC f d", :dired_open, "Open directory (Dired)")

  @impl true
  def name, do: :dired

  @impl true
  def description, do: "Oil.nvim-style directory editor"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def init(_config) do
    source = {:extension, name()}
    registry = Minga.Command.Registry

    Minga.Command.Registry.register_provider(registry, source, Commands)
    Minga.Keymap.Scope.register(source, KeymapScope)
    MingaEditor.Input.register_handler(source, Input, priority: 70)

    {:ok, %{}}
  end
end
