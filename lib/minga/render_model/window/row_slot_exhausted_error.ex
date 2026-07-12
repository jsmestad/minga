defmodule Minga.RenderModel.Window.RowSlotExhaustedError do
  @moduledoc "Raised internally when a content epoch exhausts a 28-bit row-slot scope."

  defexception message: "row slot exhaustion requires a content epoch reset"
end
