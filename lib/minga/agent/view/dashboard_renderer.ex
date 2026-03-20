defmodule Minga.Agent.View.DashboardRenderer do
  @moduledoc """
  Renders the agent dashboard sidebar: context usage, model info,
  LSP status, and working directory.

  Called by `Minga.Editor.RenderPipeline.Content` when rendering agent
  chat windows with a sidebar layout.
  """

  alias Minga.Agent.Config, as: AgentConfig
  alias Minga.Agent.ModelLimits
  alias Minga.Agent.View.RenderInput
  alias Minga.Editor.DisplayList
  alias Minga.Editor.State, as: EditorState
  alias Minga.Face
  alias Minga.Theme

  @typedoc "Screen rectangle {row_offset, col_offset, width, height}."
  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "Renders the agent dashboard sidebar (Context, Model, LSP, Directory)."
  @spec render(EditorState.t(), rect()) :: [DisplayList.draw()]
  def render(%EditorState{} = state, rect) do
    input = RenderInput.extract(state)
    render_dashboard(input, rect)
  end

  @doc """
  Returns the context window fill percentage for the current model.

  Returns nil if the model has no known context limit.
  """
  @spec context_fill_pct(map(), String.t(), non_neg_integer()) :: non_neg_integer() | nil
  def context_fill_pct(usage, model_name, context_estimate \\ 0) do
    limit = ModelLimits.context_limit(model_name)

    case limit do
      nil ->
        nil

      0 ->
        nil

      n ->
        actual = Map.get(usage, :input, 0) + Map.get(usage, :output, 0)
        # Use the higher of actual usage or pre-send estimate
        used = max(actual, context_estimate)
        min(round(used / n * 100), 100)
    end
  end

  # ── Private rendering ───────────────────────────────────────────────────────

  @spec render_dashboard(RenderInput.t(), rect()) :: [DisplayList.draw()]
  defp render_dashboard(input, {row_off, col_off, width, height}) do
    at = Theme.agent_theme(input.theme)
    blank = String.duplicate(" ", width)

    # Background fill
    bg_cmds =
      for row <- 0..(height - 1) do
        DisplayList.draw(row_off + row, col_off, blank, Face.new(bg: at.panel_bg))
      end

    sections = dashboard_sections(input, width, at)

    # Working directory pinned to bottom 2 rows
    cwd = File.cwd!() |> shorten_path()

    dir_label =
      dashboard_text(
        " Directory",
        width,
        Face.new(fg: at.dashboard_label, bg: at.panel_bg, bold: true)
      )

    dir_value = dashboard_text("  #{cwd}", width, Face.new(fg: at.text_fg, bg: at.panel_bg))

    dir_start = row_off + max(height - 2, 0)

    dir_cmds = [
      dir_label.(dir_start, col_off),
      dir_value.(min(dir_start + 1, row_off + height - 1), col_off)
    ]

    # Render sections top-down, stopping before the pinned directory
    section_limit = max(height - 3, 1)

    {section_cmds, _} =
      Enum.reduce(sections, {[], row_off}, fn line, {acc, row} ->
        if row >= row_off + section_limit do
          {acc, row}
        else
          {[line.(row, col_off) | acc], row + 1}
        end
      end)

    bg_cmds ++ Enum.reverse(section_cmds) ++ dir_cmds
  end

  @spec dashboard_sections(RenderInput.t(), pos_integer(), Theme.Agent.t()) :: [
          (non_neg_integer(), non_neg_integer() -> DisplayList.draw())
        ]
  defp dashboard_sections(input, width, at) do
    panel = input.panel
    usage = input.usage
    bare_model = AgentConfig.strip_provider_prefix(panel.model_name)

    # ── Session title section ──
    title_lines = [
      dashboard_text(
        " #{input.session_title}",
        width,
        Face.new(fg: at.header_fg, bg: at.panel_bg, bold: true)
      ),
      dashboard_blank(width, at)
    ]

    # ── Context section ──
    total_tokens = Map.get(usage, :input, 0) + Map.get(usage, :output, 0)
    estimate = input.agent_ui.context_estimate
    display_tokens = max(total_tokens, estimate)
    limit = ModelLimits.context_limit(bare_model)

    context_lines = [
      dashboard_text(
        " Context",
        width,
        Face.new(fg: at.dashboard_label, bg: at.panel_bg, bold: true)
      )
    ]

    context_lines =
      if display_tokens > 0 do
        pct_text =
          if limit,
            do: " (#{context_fill_pct(usage, bare_model, estimate) || 0}% used)",
            else: ""

        cost_text = if usage.cost > 0, do: "$#{Float.round(usage.cost, 4)}", else: "$0.00"
        cache_read = Map.get(usage, :cache_read, 0)

        context_lines ++
          [
            dashboard_text(
              "  #{format_tokens(total_tokens)} tokens#{pct_text}",
              width,
              Face.new(fg: at.text_fg, bg: at.panel_bg)
            ),
            dashboard_text(
              "  ↑ #{format_tokens(Map.get(usage, :input, 0))} in  ↓ #{format_tokens(Map.get(usage, :output, 0))} out",
              width,
              Face.new(fg: at.hint_fg, bg: at.panel_bg)
            )
          ] ++
          if cache_read > 0 do
            [
              dashboard_text(
                "  cache: #{format_tokens(cache_read)} read",
                width,
                Face.new(fg: at.hint_fg, bg: at.panel_bg)
              )
            ]
          else
            []
          end ++
          [
            dashboard_text(
              "  #{cost_text} spent",
              width,
              Face.new(fg: at.text_fg, bg: at.panel_bg)
            ),
            dashboard_blank(width, at)
          ]
      else
        context_lines ++
          [
            dashboard_text("  No usage yet", width, Face.new(fg: at.hint_fg, bg: at.panel_bg)),
            dashboard_blank(width, at)
          ]
      end

    # ── Model section ──
    thinking = if panel.thinking_level != "", do: " (#{panel.thinking_level})", else: ""

    model_lines = [
      dashboard_text(
        " Model",
        width,
        Face.new(fg: at.dashboard_label, bg: at.panel_bg, bold: true)
      ),
      dashboard_text(
        "  #{bare_model}#{thinking}",
        width,
        Face.new(fg: at.text_fg, bg: at.panel_bg)
      ),
      dashboard_blank(width, at)
    ]

    # ── LSP section ──
    lsp_lines = dashboard_lsp_section(input.lsp_servers, width, at)

    title_lines ++ context_lines ++ model_lines ++ lsp_lines
  end

  @spec dashboard_lsp_section([atom()], pos_integer(), Theme.Agent.t()) :: [
          (non_neg_integer(), non_neg_integer() -> DisplayList.draw())
        ]
  defp dashboard_lsp_section([], width, at) do
    [
      dashboard_text(
        " LSP",
        width,
        Face.new(fg: at.dashboard_label, bg: at.panel_bg, bold: true)
      ),
      dashboard_text("  No servers active", width, Face.new(fg: at.hint_fg, bg: at.panel_bg)),
      dashboard_blank(width, at)
    ]
  end

  defp dashboard_lsp_section(servers, width, at) do
    header = [
      dashboard_text(" LSP", width, Face.new(fg: at.dashboard_label, bg: at.panel_bg, bold: true))
    ]

    server_lines =
      Enum.map(servers, fn name ->
        dashboard_text("  #{name}", width, Face.new(fg: at.text_fg, bg: at.panel_bg))
      end)

    header ++ server_lines ++ [dashboard_blank(width, at)]
  end

  @spec dashboard_text(String.t(), pos_integer(), Face.t()) ::
          (non_neg_integer(), non_neg_integer() -> DisplayList.draw())
  defp dashboard_text(text, width, face) do
    padded = String.slice(text, 0, width) |> String.pad_trailing(width)
    fn row, col -> DisplayList.draw(row, col, padded, face) end
  end

  @spec dashboard_blank(pos_integer(), Theme.Agent.t()) ::
          (non_neg_integer(), non_neg_integer() -> DisplayList.draw())
  defp dashboard_blank(width, at) do
    blank = String.duplicate(" ", width)
    fn row, col -> DisplayList.draw(row, col, blank, Face.new(bg: at.panel_bg)) end
  end

  @spec shorten_path(String.t()) :: String.t()
  defp shorten_path(path) do
    home = System.user_home() || ""

    if String.starts_with?(path, home) do
      "~" <> String.trim_leading(path, home)
    else
      path
    end
  end

  @spec format_tokens(non_neg_integer()) :: String.t()
  defp format_tokens(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp format_tokens(n), do: "#{n}"
end
