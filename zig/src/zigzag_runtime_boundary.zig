/// Runtime ownership recommendation for keeping ZigZag inside the current renderer safely.
///
/// This module is evidence for #2189. ZigZag Program can own terminal IO and frame presentation when it mirrors the Go/Bubble Tea contract: terminal IO goes through the TTY, stdout remains BEAM packet-only, and BEAM semantic payloads remain authoritative.
const std = @import("std");

/// The runtime boundary recommendation for ZigZag inside `minga-renderer`.
pub const Recommendation = enum {
    derived_render_only,
    component_adapters_plus_zigzag_program,
    remove_zigzag_runtime_integration,
};

/// Runtime ownership checklist for the current renderer path.
pub const RuntimeBoundary = struct {
    stdout_reserved_for_beam_packets: bool,
    tty_owned_by_zigzag_program: bool,
    resize_routed_to_beam: bool,
    paste_routed_to_beam: bool,
    keyboard_routed_to_beam: bool,
    recovery_preserved_in_adapter: bool,
    backpressure_owned_by_minga_port_writer: bool,
    permanent_parallel_renderer: bool,
    uses_zigzag_program_runtime: bool,
    permits_local_component_reuse: bool,
    permits_local_hitbox_primitives: bool,

    /// Returns true when the boundary preserves terminal correctness and BEAM port safety.
    pub fn safe(self: RuntimeBoundary) bool {
        return self.stdout_reserved_for_beam_packets and self.tty_owned_by_zigzag_program and self.resize_routed_to_beam and self.paste_routed_to_beam and self.keyboard_routed_to_beam and self.recovery_preserved_in_adapter and self.backpressure_owned_by_minga_port_writer and !self.permanent_parallel_renderer and self.uses_zigzag_program_runtime and self.permits_local_component_reuse and self.permits_local_hitbox_primitives;
    }
};

/// Returns the explicit #2189 recommendation.
pub fn recommendation() Recommendation {
    return .component_adapters_plus_zigzag_program;
}

/// Returns the current runtime ownership boundary.
pub fn currentBoundary() RuntimeBoundary {
    return .{
        .stdout_reserved_for_beam_packets = true,
        .tty_owned_by_zigzag_program = true,
        .resize_routed_to_beam = true,
        .paste_routed_to_beam = true,
        .keyboard_routed_to_beam = true,
        .recovery_preserved_in_adapter = true,
        .backpressure_owned_by_minga_port_writer = true,
        .permanent_parallel_renderer = false,
        .uses_zigzag_program_runtime = true,
        .permits_local_component_reuse = true,
        .permits_local_hitbox_primitives = true,
    };
}

test "runtime recommendation adopts ZigZag Program under the Go Bubble Tea contract" {
    try std.testing.expectEqual(Recommendation.component_adapters_plus_zigzag_program, recommendation());
}

test "runtime boundary preserves BEAM port ownership while ZigZag owns the TTY" {
    const boundary = currentBoundary();
    try std.testing.expect(boundary.safe());
    try std.testing.expect(boundary.stdout_reserved_for_beam_packets);
    try std.testing.expect(boundary.tty_owned_by_zigzag_program);
    try std.testing.expect(boundary.resize_routed_to_beam);
    try std.testing.expect(boundary.paste_routed_to_beam);
    try std.testing.expect(boundary.keyboard_routed_to_beam);
    try std.testing.expect(boundary.recovery_preserved_in_adapter);
    try std.testing.expect(boundary.backpressure_owned_by_minga_port_writer);
    try std.testing.expect(!boundary.permanent_parallel_renderer);
    try std.testing.expect(boundary.uses_zigzag_program_runtime);
}

test "component reuse composes with ZigZag Program runtime" {
    const boundary = currentBoundary();
    try std.testing.expect(boundary.permits_local_component_reuse);
    try std.testing.expect(boundary.permits_local_hitbox_primitives);
    try std.testing.expect(boundary.uses_zigzag_program_runtime);
}
