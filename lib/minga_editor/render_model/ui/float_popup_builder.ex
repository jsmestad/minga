defmodule MingaEditor.RenderModel.UI.FloatPopupBuilder do
  @moduledoc false

  alias Minga.Buffer
  alias Minga.RenderModel.UI.FloatPopup
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @spec build(Context.t()) :: FloatPopup.t()
  def build(%Context{shell_state: %{observatory_inspection: %{visible: true} = data}} = _ctx) do
    fp = :erlang.phash2({:observatory_inspection, data})
    encoded = ProtocolGUI.encode_gui_float_popup(data)

    %FloatPopup{encoded: encoded, fingerprint: fp}
  end

  def build(%Context{} = ctx) do
    float_window = find_float_popup_window(ctx)
    fp = float_popup_fingerprint(ctx, float_window)

    encoded =
      if float_window do
        data = build_float_popup_data(ctx, float_window)
        ProtocolGUI.encode_gui_float_popup(data)
      else
        ProtocolGUI.encode_gui_float_popup(%{
          visible: false,
          title: "",
          lines: [],
          width: 0,
          height: 0
        })
      end

    %FloatPopup{encoded: encoded, fingerprint: fp}
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

  @spec float_popup_fingerprint(Context.t(), MingaEditor.Window.t() | nil) :: integer()
  defp float_popup_fingerprint(_ctx, nil), do: :erlang.phash2(nil)

  defp float_popup_fingerprint(ctx, window) do
    rule = window.popup_meta.rule
    vp = ctx.viewport
    width = resolve_float_dim(rule, :width, vp.cols)
    height = resolve_float_dim(rule, :height, vp.rows)

    buffer_fp =
      try do
        {Buffer.buffer_name(window.buffer), Buffer.version(window.buffer)}
      catch
        :exit, _ -> :dead
      end

    :erlang.phash2({window.buffer, window.popup_meta, width, height, buffer_fp})
  end

  @spec build_float_popup_data(Context.t(), MingaEditor.Window.t()) ::
          ProtocolGUI.float_popup_data()
  defp build_float_popup_data(ctx, window) do
    rule = window.popup_meta.rule
    vp = ctx.viewport

    width = resolve_float_dim(rule, :width, vp.cols)
    height = resolve_float_dim(rule, :height, vp.rows)

    # Interior dimensions (subtract 2 for border)
    interior_h = max(height - 2, 1)
    interior_w = max(width - 2, 1)

    {title, lines} =
      try do
        name = Buffer.buffer_name(window.buffer)
        snapshot = Buffer.render_snapshot(window.buffer, 0, interior_h)
        trimmed = Enum.map(snapshot.lines, &String.slice(&1, 0, interior_w))
        {name, trimmed}
      catch
        :exit, _ -> {"", []}
      end

    %{visible: true, title: title, lines: lines, width: width, height: height}
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
