defmodule Minga.UI.WhichKey.Icons do
  @moduledoc """
  Nerd Font icon mappings for which-key group prefixes.

  Maps group names (like "+file", "+git") to Nerd Font codepoints for
  display in the which-key popup. Goes beyond Doom Emacs (which has no
  icons) and matches which-key.nvim's icon support.
  """

  @type icon :: String.t()

  @icons %{
    "+file" => "󰈔",
    "+buffer" => "󰓩",
    "+git" => "",
    "+window" => "",
    "+search" => "",
    "+code" => "",
    "+help" => "󰋖",
    "+quit" => "󰗼",
    "+ai" => "󰚩",
    "+project" => "",
    "+open" => "󰏌",
    "+toggle" => "󰔡",
    "+tab" => "󰓫",
    "+filetype" => ""
  }

  @doc """
  Returns the Nerd Font icon for a group name, or `nil` if no icon is mapped.

  ## Examples

      iex> Minga.UI.WhichKey.Icons.for_group("+file")
      "󰈔"

      iex> Minga.UI.WhichKey.Icons.for_group("+unknown")
      nil
  """
  @spec for_group(String.t()) :: icon() | nil
  def for_group(group_name) when is_binary(group_name) do
    Map.get(@icons, group_name)
  end

  @doc """
  Returns all icon mappings as a map.
  """
  @spec all() :: %{String.t() => icon()}
  def all, do: @icons
end
