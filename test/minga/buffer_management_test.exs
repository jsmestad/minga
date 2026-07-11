defmodule Minga.BufferManagementTest do
  @moduledoc """
  Thin wiring coverage for ex and leader-key buffer lifecycle commands.

  Parsing, command behavior, and buffer state invariants are covered by their
  lower-layer suites.
  """

  use Minga.Test.EditorCase, async: true, rendering: :disabled

  @tag :tmp_dir
  test ":e and leader keys route buffer navigation, kill, and new commands", %{tmp_dir: dir} do
    first_path = Path.join(dir, "first.txt")
    second_path = Path.join(dir, "second.txt")
    File.write!(first_path, "first")
    File.write!(second_path, "second")

    ctx = start_editor("first", file_path: first_path)

    send_ex_sync(ctx, "e #{second_path}")
    assert active_content(ctx) == "second"

    send_keys_sync(ctx, "<SPC>bp")
    assert active_content(ctx) == "first"

    # Regression for #1476: :e must leave a valid resting mode so subsequent
    # leader commands remain usable.
    send_keys_sync(ctx, "<SPC>bn")
    assert active_content(ctx) == "second"

    send_keys_sync(ctx, "<SPC>bd")
    assert active_content(ctx) == "first"

    send_keys_sync(ctx, "<SPC>bN")
    send_keys_sync(ctx, "iwired<Esc>")
    assert active_content(ctx) == "wired"
  end
end
