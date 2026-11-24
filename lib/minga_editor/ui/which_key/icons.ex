defmodule MingaEditor.UI.WhichKey.Icons do
  @moduledoc """
  Nerd Font icon mappings for which-key group prefixes.

  Maps group labels (like "Files", "Git") to Nerd Font codepoints for
  display in the which-key popup. Goes beyond Doom Emacs (which has no
  icons) and matches which-key.nvim's icon support.
  """

  @type icon :: String.t()

  @icons %{
    "Files" => "󰈔",
    "Buffers" => "󰓩",
    "Git" => "",
    "Windows" => "",
    "Search" => "",
    "Code" => "",
    "Help" => "󰋖",
    "Quit" => "󰗼",
    "Minga" => "󰚩",
    "Project" => "",
    "Open" => "󰏌",
    "Toggles" => "󰔡",
    "Workspace" => "󰓫",
    "Filetype" => ""
  }

  @doc """
  Returns the Nerd Font icon for a group name, or `nil` if no icon is mapped.

  ## Examples

      iex> MingaEditor.UI.WhichKey.Icons.for_group("Files")
      "󰈔"

      iex> MingaEditor.UI.WhichKey.Icons.for_group("Unknown")
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
