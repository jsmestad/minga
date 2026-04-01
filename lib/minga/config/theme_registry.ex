defmodule Minga.Config.ThemeRegistry do
  @moduledoc """
  Layer 0 registry of available theme names.

  The Editor's Theme module registers builtin and user themes here at
  boot time. Config.Options and Config.Completion query this list for
  validation and tab-completion without importing from MingaEditor.*.
  """

  @persistent_key :minga_theme_registry

  # Builtin themes that are always available regardless of Editor state.
  # User themes are added on top when the Editor boots.
  @builtins [
    :catppuccin_frappe,
    :catppuccin_latte,
    :catppuccin_macchiato,
    :catppuccin_mocha,
    :doom_one,
    :one_dark,
    :one_light
  ]

  @doc "Returns the sorted list of available theme name atoms."
  @spec available() :: [atom()]
  def available do
    :persistent_term.get(@persistent_key, @builtins)
  end

  @doc "Seeds the registry with builtin themes. Called at application start."
  @spec seed_builtin() :: :ok
  def seed_builtin do
    register(@builtins)
  end

  @doc "Registers the full list of available theme names (builtins + user)."
  @spec register([atom()]) :: :ok
  def register(themes) when is_list(themes) do
    :persistent_term.put(@persistent_key, Enum.sort(themes))
    :ok
  end
end
