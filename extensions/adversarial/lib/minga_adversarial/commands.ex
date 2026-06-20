defmodule MingaAdversarial.Commands do
  @moduledoc """
  Command implementations for the adversarial extension.

  Each command reads the active file from editor state and delegates to the
  Watcher, which owns the analysis lifecycle and the skepticism dial.
  """

  alias MingaAdversarial.Watcher
  alias MingaEditor.Extension.EditorAPI

  @spec analyze(EditorAPI.state()) :: EditorAPI.state()
  def analyze(state) do
    case EditorAPI.active_path(state) do
      nil ->
        EditorAPI.set_status(state, "Adversarial: no current file")

      path ->
        case Watcher.analyze(path) do
          :off ->
            EditorAPI.set_status(
              state,
              "Adversarial: dial is off (M-x adversarial-cycle-skepticism)"
            )

          :ok ->
            EditorAPI.set_status(state, "Adversarial: challenging #{Path.basename(path)}…")
        end
    end
  end

  @spec clear(EditorAPI.state()) :: EditorAPI.state()
  def clear(state) do
    case EditorAPI.active_path(state) do
      nil ->
        EditorAPI.set_status(state, "Adversarial: no current file")

      path ->
        Watcher.clear(path)
        EditorAPI.set_status(state, "Adversarial: cleared #{Path.basename(path)}")
    end
  end

  @spec cycle_skepticism(EditorAPI.state()) :: EditorAPI.state()
  def cycle_skepticism(state) do
    EditorAPI.set_status(state, "Adversarial skepticism: #{Watcher.cycle_skepticism()}")
  end
end
