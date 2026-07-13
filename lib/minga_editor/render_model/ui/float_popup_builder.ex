defmodule MingaEditor.RenderModel.UI.FloatPopupBuilder do
  @moduledoc false

  alias Minga.Buffer
  alias Minga.RenderModel.UI.FloatPopup
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Observatory.Inspection
  alias MingaEditor.Shell.Traditional.Observatory
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState

  @max_native_popup_lines 400

  @spec build(Context.t()) :: FloatPopup.t()
  def build(%Context{shell_state: %TraditionalState{} = shell_state} = ctx) do
    case shell_state |> TraditionalState.observatory() |> Observatory.inspection() do
      %{visible: true} = inspection -> float_popup_model(inspection)
      _hidden -> build_window_popup(ctx)
    end
  end

  def build(%Context{} = ctx), do: build_window_popup(ctx)

  @spec build_window_popup(Context.t()) :: FloatPopup.t()
  defp build_window_popup(%Context{} = ctx) do
    case find_float_popup_window(ctx) do
      nil -> %FloatPopup{}
      float_window -> build_float_popup_model(ctx, float_window)
    end
  end

  @spec find_float_popup_window(Context.t()) :: MingaEditor.Window.t() | nil
  defp find_float_popup_window(ctx) do
    Enum.find_value(ctx.windows.map, fn
      {_id,
       %{
         popup_meta: %MingaEditor.UI.Popup.Active{
           rule: %Minga.Popup.Rule{display: :float}
         }
       } = w} ->
        w

      _ ->
        nil
    end)
  end

  @spec build_float_popup_model(Context.t(), MingaEditor.Window.t()) :: FloatPopup.t()
  defp build_float_popup_model(ctx, window) do
    rule = window.popup_meta.rule
    vp = ctx.viewport

    width = resolve_float_dim(rule, :width, vp.cols)
    height = resolve_float_dim(rule, :height, vp.rows)

    {title, lines} =
      try do
        name = Buffer.buffer_name(window.buffer)
        line_count = Buffer.line_count(window.buffer)

        snapshot =
          Buffer.render_snapshot(window.buffer, 0, min(line_count, @max_native_popup_lines))

        {name, snapshot.lines}
      catch
        :exit, _ -> {"", []}
      end

    %FloatPopup{visible?: true, title: title, lines: lines, width: width, height: height}
  end

  @spec float_popup_model(Inspection.t()) :: FloatPopup.t()
  defp float_popup_model(%Inspection{
         visible: true,
         title: title,
         lines: lines,
         width: width,
         height: height
       }) do
    %FloatPopup{visible?: true, title: title, lines: lines, width: width, height: height}
  end

  @spec resolve_float_dim(Minga.Popup.Rule.t(), :width | :height, pos_integer()) ::
          pos_integer()
  defp resolve_float_dim(rule, dim, viewport_size) do
    val =
      case dim do
        :width -> rule.width || rule.size || {:percent, 50}
        :height -> rule.height || rule.size || {:percent, 50}
      end

    case val do
      {:percent, pct} -> max(div(viewport_size * pct, 100), 1)
      {:cols, n} -> n
      {:rows, n} -> n
      n when is_integer(n) -> n
      _ -> max(div(viewport_size, 2), 1)
    end
  end
end
