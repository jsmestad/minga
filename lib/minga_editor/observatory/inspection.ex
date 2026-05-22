defmodule MingaEditor.Observatory.Inspection do
  @moduledoc """
  User-visible process inspection result rendered through the native float popup.
  """

  @enforce_keys [:visible, :title, :lines, :width, :height]
  defstruct [:visible, :title, :lines, :width, :height]

  @type t :: %__MODULE__{
          visible: boolean(),
          title: String.t(),
          lines: [String.t()],
          width: pos_integer(),
          height: pos_integer()
        }

  @doc "Builds a visible process inspection popup."
  @spec visible(String.t(), [String.t()]) :: t()
  def visible(title, lines) when is_binary(title) and is_list(lines) do
    %__MODULE__{
      visible: true,
      title: title,
      lines: lines,
      width: 82,
      height: min(max(length(lines) + 4, 10), 30)
    }
  end
end
