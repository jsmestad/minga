defmodule MingaAdversarial do
  @moduledoc """
  An adversarial pair programmer that challenges the assumptions in your code.

  On demand (or, depending on the skepticism dial, on save) it sends the
  current file to the model with an adversarial prompt ("what does this code
  assume that could break?") and surfaces the answers as advisory gutter
  findings (amber `?`) you can read on hover and step through with the normal
  diagnostic navigation. Findings clear themselves as you edit.

  The **skepticism dial** (`:skepticism` option) controls how eager it is:

    * `:off`: disabled; the analyze command is a no-op.
    * `:manual`: only the `adversarial-analyze` command runs it (default).
    * `:on_save`: also analyzes on save.
    * `:paranoid`: analyzes on save with a maximally skeptical prompt.

  Default is `:manual`, so there is zero background model spend until you ask.

  Keybindings (under the `SPC a` "+ai" leader):

    * `SPC a A`: challenge assumptions in the current file now

  Also `M-x adversarial-analyze`, `M-x adversarial-clear`, and
  `M-x adversarial-cycle-skepticism`.
  """

  use Minga.Extension.Editor

  option(:skepticism, {:enum, [:off, :manual, :on_save, :paranoid]},
    default: :manual,
    description: "How eager the adversary is: off, manual, on_save, or paranoid"
  )

  command(:adversarial_analyze, "Challenge assumptions in the current file",
    execute: {MingaAdversarial.Commands, :analyze}
  )

  command(:adversarial_clear, "Clear adversarial observations for the current file",
    execute: {MingaAdversarial.Commands, :clear}
  )

  command(:adversarial_cycle_skepticism, "Cycle the adversarial skepticism dial",
    execute: {MingaAdversarial.Commands, :cycle_skepticism}
  )

  keybind(:normal, "SPC a A", :adversarial_analyze, "Adversarial: challenge current file")

  @impl true
  def name, do: :minga_adversarial

  @impl true
  def description, do: "Challenges the assumptions in your code"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def init(_config), do: {:ok, %{}}

  @impl true
  def child_spec(_config) do
    %{
      id: MingaAdversarial.Watcher,
      start: {MingaAdversarial.Watcher, :start_link, [[]]},
      restart: :permanent,
      type: :worker
    }
  end
end
