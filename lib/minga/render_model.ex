defmodule Minga.RenderModel do
  @moduledoc """
  Top-level visible model for one rendered frame.

  Products such as `MingaEditor` derive this struct from their own state, then frontend adapters translate it to protocol commands. The struct is pure data and lives in core so adapters can consume one visible truth instead of parallel window, chrome, cursor, and side-channel payloads.
  """

  alias Minga.RenderModel.Cursor
  alias Minga.RenderModel.UI
  alias Minga.RenderModel.Window

  @enforce_keys [:windows, :ui, :cursor]
  defstruct windows: [],
            ui: %UI{},
            cursor: nil,
            title: nil,
            window_bg: nil

  @type t :: %__MODULE__{
          windows: [Window.t()],
          ui: UI.t(),
          cursor: Cursor.t(),
          title: String.t() | nil,
          window_bg: non_neg_integer() | nil
        }

  @doc "Creates a top-level frame render model."
  @spec new([Window.t()], UI.t(), Cursor.t(), String.t() | nil, non_neg_integer() | nil) :: t()
  def new(windows, %UI{} = ui, %Cursor{} = cursor, title \\ nil, window_bg \\ nil)
      when is_list(windows) do
    %__MODULE__{windows: windows, ui: ui, cursor: cursor, title: title, window_bg: window_bg}
  end
end
