defmodule MingaGitPorcelain.Feature do
  @moduledoc """
  Source-owned contribution registration for the bundled Git porcelain extension.
  """

  alias Minga.Extension.ContributionCleanup
  alias Minga.Keymap.Scope
  alias MingaEditor.Input

  @source {:extension, :minga_git_porcelain}
  @input_source {:extension, :minga_git_porcelain}

  @doc "Contribution source that owns Git porcelain registrations."
  @spec source() :: {:extension, :minga_git_porcelain}
  def source, do: @source

  @doc "Registers Git porcelain input and keymap scope contributions."
  @spec register_contributions() :: :ok
  def register_contributions do
    :ok = Input.register_handler(@input_source, MingaGitPorcelain.Input.GitStatus, priority: 60)
    :ok = Scope.register(@source, MingaGitPorcelain.Keymap.Scope)
    ContributionCleanup.register(:keymap_scopes, &Scope.unregister_source/1)
  end
end
