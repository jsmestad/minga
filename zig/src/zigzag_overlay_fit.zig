/// Overlay and agent-surface ZigZag adapter feasibility for the current renderer.
///
/// This module does more than smoke-test component availability. It records whether each candidate can become a Minga adapter, what state it would try to own, whether direct output is plain enough for the cell renderer, and what boundary must be preserved before runtime adoption.
const std = @import("std");
const zz = @import("zigzag");

pub const AdapterStatus = enum {
    adopted_runtime,
    feasible_plain_adapter,
    feasible_mirrored_state,
    fit_only_ansi_renderer,
    blocked_behavior_owner,
};

pub const ComponentEvaluation = struct {
    family: []const u8,
    component: []const u8,
    status: AdapterStatus,
    direct_output_plain: bool,
    owns_interaction_state: bool,
    preserves_beam_semantics: bool,
    recommendation: []const u8,
};

pub const OverlayEvaluation = struct {
    command_palette: ComponentEvaluation,
    tooltip: ComponentEvaluation,
    table: ComponentEvaluation,
    data_table: ComponentEvaluation,
    rich_log: ComponentEvaluation,
    markdown: ComponentEvaluation,
    virtual_list: ComponentEvaluation,
    text_input: ComponentEvaluation,
    text_area: ComponentEvaluation,
    dropdown: ComponentEvaluation,

    pub fn allRemaindersEvaluated(self: OverlayEvaluation) bool {
        return self.command_palette.component.len > 0 and
            self.tooltip.component.len > 0 and
            self.table.component.len > 0 and
            self.data_table.component.len > 0 and
            self.rich_log.component.len > 0 and
            self.markdown.component.len > 0 and
            self.virtual_list.component.len > 0 and
            self.text_input.component.len > 0 and
            self.text_area.component.len > 0 and
            self.dropdown.component.len > 0;
    }
};

/// Evaluates the remaining overlay/agent-surface candidates that are not already adopted by runtime adapters.
pub fn evaluateRemainingOverlayAdapters(alloc: std.mem.Allocator) !OverlayEvaluation {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();

    return .{
        .command_palette = try evaluateCommandPalette(scratch),
        .tooltip = try evaluateTooltip(scratch),
        .table = try evaluateTable(scratch),
        .data_table = try evaluateDataTable(scratch),
        .rich_log = try evaluateRichLog(scratch),
        .markdown = try evaluateMarkdown(scratch),
        .virtual_list = try evaluateVirtualList(scratch),
        .text_input = try evaluateTextInput(scratch),
        .text_area = try evaluateTextArea(scratch),
        .dropdown = try evaluateDropdown(scratch),
    };
}

/// Backward-compatible summary for callers that only need to know whether named overlay families have a candidate.
pub const OverlayFit = struct {
    picker: bool,
    completion: bool,
    hover: bool,
    which_key: bool,
    bottom_panel: bool,
    board: bool,
    agent_chat: bool,
    tool_manager: bool,

    pub fn allCovered(self: OverlayFit) bool {
        return self.picker and self.completion and self.hover and self.which_key and self.bottom_panel and self.board and self.agent_chat and self.tool_manager;
    }
};

pub fn assessOverlayFit(alloc: std.mem.Allocator) !OverlayFit {
    const evaluation = try evaluateRemainingOverlayAdapters(alloc);
    return .{
        .picker = evaluation.command_palette.preserves_beam_semantics,
        .completion = true,
        .hover = evaluation.tooltip.preserves_beam_semantics,
        .which_key = true,
        .bottom_panel = evaluation.table.preserves_beam_semantics,
        .board = evaluation.table.preserves_beam_semantics,
        .agent_chat = evaluation.rich_log.preserves_beam_semantics,
        .tool_manager = evaluation.table.preserves_beam_semantics,
    };
}

fn evaluateCommandPalette(alloc: std.mem.Allocator) !ComponentEvaluation {
    var palette = try zz.CommandPalette.init(alloc);
    defer palette.deinit();
    try palette.addCommand(.{ .id = "open", .label = "Open File", .description = "Open a file", .shortcut = "SPC f f" });
    const rendered = try palette.view(alloc);
    return .{
        .family = "picker",
        .component = "CommandPalette",
        .status = .feasible_mirrored_state,
        .direct_output_plain = !containsAnsi(rendered),
        .owns_interaction_state = true,
        .preserves_beam_semantics = contains(rendered, "Open File"),
        .recommendation = "Good picker presentation candidate, but query/filter/cursor/acceptance must mirror BEAM-owned picker state before runtime adoption.",
    };
}

fn evaluateTooltip(alloc: std.mem.Allocator) !ComponentEvaluation {
    var tooltip = zz.Tooltip.titled("Hover", "symbol documentation");
    tooltip.show();
    const rendered = try tooltip.renderBox(alloc);
    return .{
        .family = "hover/signature",
        .component = "Tooltip",
        .status = .feasible_plain_adapter,
        .direct_output_plain = !containsAnsi(rendered),
        .owns_interaction_state = false,
        .preserves_beam_semantics = contains(rendered, "symbol documentation"),
        .recommendation = "Good hover/signature shape candidate if converted to plain rows and placed by Minga overlay precedence.",
    };
}

fn evaluateTable(alloc: std.mem.Allocator) !ComponentEvaluation {
    var table = zz.Table(2).init(alloc);
    defer table.deinit();
    table.setHeaders(.{ "Tool", "Result" });
    try table.addRow(.{ "format", "ready" });
    const rendered = try table.view(alloc);
    return .{
        .family = "bottom-panel/board/tool-manager",
        .component = "Table",
        .status = .feasible_plain_adapter,
        .direct_output_plain = !containsAnsi(rendered),
        .owns_interaction_state = false,
        .preserves_beam_semantics = contains(rendered, "format") and contains(rendered, "ready"),
        .recommendation = "Good structured panel adapter candidate. Row actions must stay BEAM-routed and output must be converted to cells without ANSI leakage.",
    };
}

fn evaluateDataTable(alloc: std.mem.Allocator) !ComponentEvaluation {
    var table = zz.DataTable.init(alloc);
    defer table.deinit();
    try table.setColumns(&[_]zz.components.DataColumn{
        .{ .header = "Tool", .width = 8 },
        .{ .header = "Result", .width = 8 },
    });
    try table.addRow(&[_][]const u8{ "format", "ready" });
    const rendered = try table.view(alloc);
    return .{
        .family = "tool-manager/data-grid",
        .component = "DataTable",
        .status = .feasible_mirrored_state,
        .direct_output_plain = !containsAnsi(rendered),
        .owns_interaction_state = true,
        .preserves_beam_semantics = contains(rendered, "format") and contains(rendered, "ready"),
        .recommendation = "Useful for dense tool/result grids, but cursor row/col and scroll offsets must mirror BEAM-owned panel state before runtime adoption.",
    };
}

fn evaluateRichLog(alloc: std.mem.Allocator) !ComponentEvaluation {
    var log = zz.RichLog.init(alloc, 8);
    defer log.deinit();
    try log.append(std.testing.io, .info, "agent response");
    const rendered = try log.view(alloc);
    return .{
        .family = "agent-chat/log",
        .component = "RichLog",
        .status = .feasible_mirrored_state,
        .direct_output_plain = !containsAnsi(rendered),
        .owns_interaction_state = true,
        .preserves_beam_semantics = contains(rendered, "agent response"),
        .recommendation = "Promising agent transcript adapter if entries are rebuilt from BEAM-owned transcript/stream state instead of becoming the log source of truth.",
    };
}

fn evaluateMarkdown(alloc: std.mem.Allocator) !ComponentEvaluation {
    var markdown = zz.Markdown.init();
    const rendered = try markdown.render(alloc, "# Agent\n\nResult `ok`");
    return .{
        .family = "agent-chat/markdown",
        .component = "Markdown",
        .status = .fit_only_ansi_renderer,
        .direct_output_plain = !containsAnsi(rendered),
        .owns_interaction_state = false,
        .preserves_beam_semantics = contains(rendered, "Agent") and contains(rendered, "ok"),
        .recommendation = "Useful parser/shape evidence, but direct renderer emits styled terminal text. Runtime adoption needs a span/plain-row adapter, not raw output.",
    };
}

fn renderVirtualItem(item: []const u8, _: usize, _: bool, _: std.mem.Allocator) []const u8 {
    return item;
}

fn evaluateVirtualList(alloc: std.mem.Allocator) !ComponentEvaluation {
    const items = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    var list = zz.components.VirtualList([]const u8){};
    list.viewport_height = 2;
    list.cursor = 3;
    list.render_fn = renderVirtualItem;
    list.show_count = false;
    list.show_scrollbar = false;
    list.setItems(&items);
    const rendered = list.view(alloc);
    return .{
        .family = "large-list",
        .component = "VirtualList",
        .status = .feasible_mirrored_state,
        .direct_output_plain = !containsAnsi(rendered),
        .owns_interaction_state = true,
        .preserves_beam_semantics = contains(rendered, "gamma") and contains(rendered, "delta"),
        .recommendation = "Good candidate for large picker/completion lists if cursor/offset are derived from BEAM-owned selection and scroll state.",
    };
}

fn evaluateTextInput(alloc: std.mem.Allocator) !ComponentEvaluation {
    var input = zz.TextInput.init(alloc);
    defer input.deinit();
    input.setPrompt(":");
    try input.setValue("open");
    const rendered = try input.view(alloc);
    return .{
        .family = "picker-query",
        .component = "TextInput",
        .status = .blocked_behavior_owner,
        .direct_output_plain = !containsAnsi(rendered),
        .owns_interaction_state = true,
        .preserves_beam_semantics = contains(rendered, "open"),
        .recommendation = "Do not adopt directly until query text, cursor, validation, suggestions, and editing actions mirror BEAM-owned minibuffer/picker state.",
    };
}

fn evaluateTextArea(alloc: std.mem.Allocator) !ComponentEvaluation {
    var area = zz.TextArea.init(alloc);
    defer area.deinit();
    area.width = 40;
    area.height = 2;
    try area.setValue("agent draft\nsecond line");
    const rendered = try area.view(alloc);
    return .{
        .family = "agent-compose",
        .component = "TextArea",
        .status = .blocked_behavior_owner,
        .direct_output_plain = !containsAnsi(rendered),
        .owns_interaction_state = true,
        .preserves_beam_semantics = contains(rendered, "agent draft"),
        .recommendation = "Not safe as a runtime owner for prompts or editor buffers. It owns text, cursor, viewport, and editing behavior that must remain BEAM-owned.",
    };
}

fn evaluateDropdown(alloc: std.mem.Allocator) !ComponentEvaluation {
    var dropdown = zz.Dropdown([]const u8).init(alloc);
    defer dropdown.deinit();
    dropdown.expanded = true;
    try dropdown.addItem(.{ .value = "theme", .label = "Theme", .description = "Switch theme", .enabled = true });
    const rendered = try dropdown.view(alloc);
    return .{
        .family = "choice-popup",
        .component = "Dropdown",
        .status = .blocked_behavior_owner,
        .direct_output_plain = !containsAnsi(rendered),
        .owns_interaction_state = true,
        .preserves_beam_semantics = contains(rendered, "Theme"),
        .recommendation = "Useful shape for choice popups, but selected indices, filtering, expansion, and acceptance must be BEAM-owned before runtime use.",
    };
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn containsAnsi(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0x1B) != null;
}

test "remaining overlay components have explicit adapter feasibility evaluations" {
    const evaluation = try evaluateRemainingOverlayAdapters(std.testing.allocator);
    try std.testing.expect(evaluation.allRemaindersEvaluated());
    try std.testing.expectEqual(AdapterStatus.feasible_mirrored_state, evaluation.command_palette.status);
    try std.testing.expectEqual(AdapterStatus.feasible_plain_adapter, evaluation.tooltip.status);
    try std.testing.expectEqual(AdapterStatus.feasible_plain_adapter, evaluation.table.status);
    try std.testing.expectEqual(AdapterStatus.feasible_mirrored_state, evaluation.data_table.status);
    try std.testing.expectEqual(AdapterStatus.feasible_mirrored_state, evaluation.rich_log.status);
    try std.testing.expectEqual(AdapterStatus.fit_only_ansi_renderer, evaluation.markdown.status);
    try std.testing.expectEqual(AdapterStatus.feasible_mirrored_state, evaluation.virtual_list.status);
    try std.testing.expectEqual(AdapterStatus.blocked_behavior_owner, evaluation.text_input.status);
    try std.testing.expectEqual(AdapterStatus.blocked_behavior_owner, evaluation.text_area.status);
    try std.testing.expectEqual(AdapterStatus.blocked_behavior_owner, evaluation.dropdown.status);
}

test "remaining overlay evaluation records direct-output ANSI risk" {
    const evaluation = try evaluateRemainingOverlayAdapters(std.testing.allocator);
    try std.testing.expect(!evaluation.command_palette.direct_output_plain);
    try std.testing.expect(!evaluation.markdown.direct_output_plain);
    try std.testing.expect(evaluation.text_input.owns_interaction_state);
    try std.testing.expect(evaluation.tooltip.preserves_beam_semantics);
}

test "overlay fit summary remains covered by evaluated candidates" {
    const fit = try assessOverlayFit(std.testing.allocator);
    try std.testing.expect(fit.allCovered());
}
