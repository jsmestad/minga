defmodule Minga.Keymap.Defaults do
  @moduledoc """
  Doom Emacs-style default leader keybindings for Minga.

  All bindings are rooted at the **SPC** (space) leader key in Normal mode.
  Group prefix nodes are labelled with `+group` descriptions so that the
  which-key popup can display them meaningfully.

  ## Key groups

  | Prefix    | Group       |
  |-----------|-------------|
  | `SPC f`   | +file       |
  | `SPC b`   | +buffer     |
  | `SPC w`   | +window     |
  | `SPC q`   | +quit       |
  | `SPC h`   | +help       |
  """

  alias Minga.Keymap.Trie

  @none 0x00

  # ---------------------------------------------------------------------------
  # Leaf bindings: {key_sequence, command_atom, description}
  # Key sequences are relative to the leader key (SPC is implicit).
  # ---------------------------------------------------------------------------

  @leader_bindings [
    # ── File ──────────────────────────────────────────────────────────────────
    {[{?f, @none}, {?f, @none}], :find_file, "Find file"},
    {[{?f, @none}, {?s, @none}], :save, "Save file"},

    # ── Buffer ────────────────────────────────────────────────────────────────
    {[{?b, @none}, {?b, @none}], :buffer_list, "Switch buffer"},
    {[{?b, @none}, {?n, @none}], :buffer_next, "Next buffer"},
    {[{?b, @none}, {?p, @none}], :buffer_prev, "Previous buffer"},
    {[{?b, @none}, {?d, @none}], :kill_buffer, "Kill buffer"},

    # ── Window ────────────────────────────────────────────────────────────────
    {[{?w, @none}, {?h, @none}], :window_left, "Window left"},
    {[{?w, @none}, {?j, @none}], :window_down, "Window down"},
    {[{?w, @none}, {?k, @none}], :window_up, "Window up"},
    {[{?w, @none}, {?l, @none}], :window_right, "Window right"},
    {[{?w, @none}, {?v, @none}], :split_vertical, "Vertical split"},
    {[{?w, @none}, {?s, @none}], :split_horizontal, "Horizontal split"},

    # ── Quit ──────────────────────────────────────────────────────────────────
    {[{?q, @none}, {?q, @none}], :quit, "Quit editor"},

    # ── Help ──────────────────────────────────────────────────────────────────
    {[{?h, @none}, {?k, @none}], :describe_key, "Describe key"}
  ]

  # Group prefix descriptions shown in which-key at the SPC level.
  @group_prefixes [
    {[{?f, @none}], "+file"},
    {[{?b, @none}], "+buffer"},
    {[{?w, @none}], "+window"},
    {[{?q, @none}], "+quit"},
    {[{?h, @none}], "+help"}
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns a trie whose root is the SPC leader key's subtrie.

  The returned node can be passed directly to `Minga.Keymap.Trie.lookup/2` for
  subsequent keys in the leader sequence.
  """
  @spec leader_trie() :: Trie.node_t()
  def leader_trie do
    trie_with_bindings =
      Enum.reduce(@leader_bindings, Trie.new(), fn {keys, command, description}, trie ->
        Trie.bind(trie, keys, command, description)
      end)

    Enum.reduce(@group_prefixes, trie_with_bindings, fn {keys, description}, trie ->
      Trie.bind_prefix(trie, keys, description)
    end)
  end

  @doc """
  Returns the leader key as a `t:Minga.Keymap.Trie.key/0` tuple (SPC = `{32, 0}`).
  """
  @spec leader_key() :: Trie.key()
  def leader_key, do: {32, @none}

  @doc """
  Returns all leader bindings as a flat list of `{key_sequence, command, description}` tuples.
  """
  @spec all_bindings() :: [{[Trie.key()], atom(), String.t()}]
  def all_bindings, do: @leader_bindings
end
