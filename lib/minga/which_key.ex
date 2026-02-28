defmodule Minga.WhichKey do
  @moduledoc """
  Which-key popup utility for Minga.

  Provides key formatting and binding display helpers used when the editor
  is waiting for the next key in a leader-key sequence. After a configurable
  timeout (default 300 ms), a popup is shown listing all available continuations
  of the current prefix.

  ## Timer contract

  `start_timeout/1` sends `{:whichkey_timeout, ref}` to the **calling process**
  after the given number of milliseconds, where `ref` is the opaque reference
  returned by the call. The caller can cancel the timer with `cancel_timeout/1`
  before it fires.

  ## Key formatting

  | Input                   | Output  |
  |-------------------------|---------|
  | `{32, 0}`               | `"SPC"` |
  | `{?s, 0x02}`            | `"C-s"` |
  | `{?s, 0x06}`            | `"C-M-s"` |
  | `{?s, 0x04}`            | `"M-s"` |
  | `{?j, 0x00}`            | `"j"`   |
  """

  import Bitwise

  alias Minga.Keymap.Trie

  @typedoc "A formatted binding entry for display."
  @type binding :: %{key: String.t(), description: String.t()}

  @typedoc "An opaque timer reference returned by `start_timeout/1`."
  @type timer_ref :: reference()

  @default_timeout_ms 300

  # ── Timer API ────────────────────────────────────────────────────────────────

  @doc """
  Starts a which-key popup timer.

  After `timeout_ms` milliseconds (default #{@default_timeout_ms} ms), sends
  `{:whichkey_timeout, ref}` to the calling process. Returns the `ref` that
  will be included in the message so the caller can identify it.
  """
  @spec start_timeout(non_neg_integer()) :: timer_ref()
  def start_timeout(timeout_ms \\ @default_timeout_ms)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    ref = make_ref()
    Process.send_after(self(), {:whichkey_timeout, ref}, timeout_ms)
    ref
  end

  @doc """
  Cancels a which-key timer before it fires.

  Safe to call even if the timer has already fired; in that case the message
  may already be in the process mailbox.

  Always returns `:ok`.
  """
  @spec cancel_timeout(timer_ref()) :: :ok
  def cancel_timeout(ref) when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  # ── Key formatting ────────────────────────────────────────────────────────────

  @doc """
  Formats a single `t:Minga.Keymap.Trie.key/0` tuple into a human-readable string.

  ## Examples

      iex> Minga.WhichKey.format_key({32, 0})
      "SPC"

      iex> Minga.WhichKey.format_key({?s, 0x02})
      "C-s"

      iex> Minga.WhichKey.format_key({?j, 0x00})
      "j"
  """
  @spec format_key(Trie.key()) :: String.t()
  def format_key({32, 0}), do: "SPC"

  def format_key({27, _}), do: "ESC"

  def format_key({codepoint, modifiers}) do
    char = <<codepoint::utf8>>
    modifier_prefix(modifiers) <> char
  end

  # ── Binding display ───────────────────────────────────────────────────────────

  @doc """
  Formats a list of `{key, label}` pairs (as returned by `Minga.Keymap.Trie.children/1`)
  into a list of `t:binding/0` maps suitable for rendering in a which-key popup.
  """
  @spec format_bindings([{Trie.key(), String.t() | atom()}]) :: [binding()]
  def format_bindings(children) when is_list(children) do
    Enum.map(children, fn {key, label} ->
      %{
        key: format_key(key),
        description: format_label(label)
      }
    end)
  end

  @doc """
  Produces a sorted list of `t:binding/0` maps from the direct children of a
  trie node. This is the primary function used to build which-key popup content.
  """
  @spec bindings_from_node(Trie.node_t()) :: [binding()]
  def bindings_from_node(node) do
    node
    |> Trie.children()
    |> format_bindings()
    |> Enum.sort_by(& &1.key)
  end

  @doc """
  Renders a which-key popup as a plain-text list of columns.

  Returns a list of strings, one per row, each of the form `"  key  description"`.
  Suitable for drawing with the port renderer.
  """
  @spec render_popup([binding()]) :: [String.t()]
  def render_popup(bindings) when is_list(bindings) do
    Enum.map(bindings, fn %{key: key, description: desc} ->
      padded_key = String.pad_trailing(key, 8)
      "  #{padded_key}#{desc}"
    end)
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  @spec modifier_prefix(non_neg_integer()) :: String.t()
  defp modifier_prefix(modifiers) do
    ctrl = band(modifiers, 0x02) != 0
    alt = band(modifiers, 0x04) != 0

    cond do
      ctrl and alt -> "C-M-"
      ctrl -> "C-"
      alt -> "M-"
      true -> ""
    end
  end

  @spec format_label(String.t() | atom()) :: String.t()
  defp format_label(label) when is_binary(label), do: label
  defp format_label(:prefix), do: "+prefix"
  defp format_label(:unknown), do: "?"
  defp format_label(label) when is_atom(label), do: Atom.to_string(label)
end
