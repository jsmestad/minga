defmodule Minga.UI.Popup.Rule do
  @moduledoc """
  Declarative rule for how a popup buffer should be displayed.

  Each rule matches a buffer name (by exact string or regex) and specifies
  the display mode, positioning, sizing, and behavior. Rules are registered
  in the `Popup.Registry` and checked when a buffer is opened.

  ## Display modes

  - `:split` — edge-anchored managed pane (Doom Emacs style). The popup
    appears as a temporary split on one side of the editor, governed by
    `side` and `size`. Closing the popup restores the original layout.

  - `:float` — bordered floating panel (Neovim/LazyVim style). The popup
    appears as an overlay with configurable `width`, `height`, `position`,
    and `border` style. Requires the FloatingWindow primitive (#343).

  ## Examples

      Popup.Rule.new("*Warnings*", side: :bottom, size: {:percent, 30}, focus: false)

      Popup.Rule.new(~r/\\*Help/, display: :float, width: {:percent, 60},
        height: {:percent, 70}, border: :rounded, focus: true, auto_close: true)
  """

  @typedoc "How the popup is rendered."
  @type display :: :split | :float

  @typedoc "Which edge a split popup anchors to."
  @type side :: :bottom | :right | :left | :top

  @typedoc "Popup size as a percentage of available space or fixed rows/cols."
  @type size :: {:percent, 1..100} | {:rows, pos_integer()} | {:cols, pos_integer()}

  @typedoc "Popup position for float display mode."
  @type position :: :center | {:offset, integer(), integer()}

  @typedoc "Border style for float display mode."
  @type border :: :rounded | :single | :double | :none

  @type t :: %__MODULE__{
          pattern: Regex.t() | String.t(),
          display: display(),
          side: side(),
          size: size(),
          width: size() | nil,
          height: size() | nil,
          position: position(),
          border: border(),
          focus: boolean(),
          auto_close: boolean(),
          quit_key: String.t(),
          modeline: boolean(),
          priority: integer()
        }

  @enforce_keys [:pattern]
  defstruct pattern: nil,
            display: :split,
            side: :bottom,
            size: {:percent, 30},
            width: nil,
            height: nil,
            position: :center,
            border: :rounded,
            focus: true,
            auto_close: false,
            quit_key: "q",
            modeline: false,
            priority: 0

  @valid_displays [:split, :float]
  @valid_sides [:bottom, :right, :left, :top]
  @valid_borders [:rounded, :single, :double, :none]

  @doc """
  Creates a new popup rule from a pattern and keyword options.

  The pattern can be an exact string (e.g. `"*Warnings*"`) or a
  `Regex` (e.g. `~r/\\*Help/`). All other fields are optional and
  default to a bottom split at 30% height with focus.

  Raises `ArgumentError` if any option is invalid.

  ## Options

  - `:display` — `:split` (default) or `:float`
  - `:side` — `:bottom` (default), `:right`, `:left`, `:top` (split mode)
  - `:size` — `{:percent, n}` or `{:rows, n}` / `{:cols, n}` (split mode, default `{:percent, 30}`)
  - `:width` — float mode width (default nil, uses `{:percent, 50}` when display is `:float`)
  - `:height` — float mode height (default nil, uses `{:percent, 50}` when display is `:float`)
  - `:position` — `:center` (default) or `{:offset, row, col}` (float mode)
  - `:border` — `:rounded` (default), `:single`, `:double`, `:none` (float mode)
  - `:focus` — whether opening the popup steals focus (default `true`)
  - `:auto_close` — close when the popup loses focus (default `false`)
  - `:quit_key` — key to dismiss the popup (default `"q"`)
  - `:modeline` — show a modeline in the popup (default `false`, split mode only)
  - `:priority` — rule ordering; higher priority wins on conflict (default `0`)
  """
  @spec new(Regex.t() | String.t(), keyword()) :: t()
  def new(pattern, opts \\ []) when is_binary(pattern) or is_struct(pattern, Regex) do
    rule = %__MODULE__{pattern: pattern}

    rule =
      Enum.reduce(opts, rule, fn {key, value}, acc ->
        apply_option(acc, key, value)
      end)

    validate!(rule)
    rule
  end

  @doc """
  Returns true if the given buffer name matches this rule's pattern.

  String patterns match exactly. Regex patterns match anywhere in the name.
  """
  @spec matches?(t(), String.t()) :: boolean()
  def matches?(%__MODULE__{pattern: pattern}, buffer_name) when is_binary(buffer_name) do
    case pattern do
      p when is_binary(p) -> p == buffer_name
      %Regex{} = r -> Regex.match?(r, buffer_name)
    end
  end

  # ── Option application ────────────────────────────────────────────────────

  @spec apply_option(t(), atom(), term()) :: t()
  defp apply_option(rule, :display, value) when value in @valid_displays do
    %{rule | display: value}
  end

  defp apply_option(rule, :side, value) when value in @valid_sides do
    %{rule | side: value}
  end

  defp apply_option(rule, :size, value) do
    validate_size!(value)
    %{rule | size: value}
  end

  defp apply_option(rule, :width, value) do
    validate_size!(value)
    %{rule | width: value}
  end

  defp apply_option(rule, :height, value) do
    validate_size!(value)
    %{rule | height: value}
  end

  defp apply_option(rule, :position, :center), do: %{rule | position: :center}

  defp apply_option(rule, :position, {:offset, row, col})
       when is_integer(row) and is_integer(col) do
    %{rule | position: {:offset, row, col}}
  end

  defp apply_option(rule, :border, value) when value in @valid_borders do
    %{rule | border: value}
  end

  defp apply_option(rule, :focus, value) when is_boolean(value) do
    %{rule | focus: value}
  end

  defp apply_option(rule, :auto_close, value) when is_boolean(value) do
    %{rule | auto_close: value}
  end

  defp apply_option(rule, :quit_key, value) when is_binary(value) do
    %{rule | quit_key: value}
  end

  defp apply_option(rule, :modeline, value) when is_boolean(value) do
    %{rule | modeline: value}
  end

  defp apply_option(rule, :priority, value) when is_integer(value) do
    %{rule | priority: value}
  end

  defp apply_option(_rule, key, value) do
    raise ArgumentError,
          "invalid popup rule option #{inspect(key)} with value #{inspect(value)}"
  end

  # ── Validation ─────────────────────────────────────────────────────────────

  @spec validate!(t()) :: :ok
  defp validate!(%__MODULE__{} = rule) do
    validate_display_options!(rule)
    :ok
  end

  @spec validate_display_options!(t()) :: :ok
  defp validate_display_options!(%__MODULE__{display: :split, size: size}) do
    validate_size!(size)
    :ok
  end

  defp validate_display_options!(%__MODULE__{display: :float}) do
    :ok
  end

  @spec validate_size!(term()) :: :ok
  defp validate_size!({:percent, n}) when is_integer(n) and n >= 1 and n <= 100, do: :ok
  defp validate_size!({:rows, n}) when is_integer(n) and n >= 1, do: :ok
  defp validate_size!({:cols, n}) when is_integer(n) and n >= 1, do: :ok

  defp validate_size!(value) do
    raise ArgumentError,
          "invalid popup size #{inspect(value)}, expected {:percent, 1..100}, {:rows, n}, or {:cols, n}"
  end
end
