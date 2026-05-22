defmodule MingaEditor.BufferDecorations do
  @moduledoc """
  Shared transient decoration composition for buffer render and hit-testing.

  Buffer-owned decorations are the base. Editor features such as inline ask, inline edit, and merge conflict actions add derived decorations for the current frame. Keeping this in one module prevents rendered block decorations from disagreeing with mouse hit-testing.
  """

  alias Minga.Buffer
  alias Minga.Core.Decorations
  alias MingaEditor.InlineAsk.Render, as: InlineAskRender
  alias MingaEditor.InlineEdit.Render, as: InlineEditRender
  alias MingaEditor.MergeConflict.Render, as: MergeConflictRender

  @type state :: MingaEditor.State.t() | map()

  @doc "Returns base buffer decorations plus editor-owned transient decorations."
  @spec compose(state(), pid()) :: Decorations.t()
  def compose(state, buf) when is_pid(buf) do
    state
    |> compose(buf, Buffer.decorations(buf))
  catch
    :exit, _ -> Decorations.new()
  end

  @doc "Adds editor-owned transient decorations to an existing decoration set."
  @spec compose(state(), pid(), Decorations.t()) :: Decorations.t()
  def compose(state, buf, %Decorations{} = decorations) when is_pid(buf) do
    decorations
    |> InlineAskRender.merge_decorations(state, buf)
    |> InlineEditRender.merge_decorations(state, buf)
    |> MergeConflictRender.merge_decorations(state, buf)
  catch
    :exit, _ -> decorations
  end

  def compose(_state, _buf, %Decorations{} = decorations), do: decorations
end
