defmodule Minga.Frontend.PickerHintLiteralsTest do
  @moduledoc """
  The empty picker's footer names the keys the BEAM resolves from the live picker keymap (`Minga.Keymap.PromptKeys.picker_hints/3`).

  A frontend that spells a movement key into hint text would stop following a rebind, so neither frontend's picker code may hold one.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  @picker_sources [
    "go/tui/internal/ui/render_chrome.go",
    "macos/Sources/Views/Overlays/PickerOverlay.swift"
  ]

  # A string literal that names movement keys next to the word "move", such as "j k move" or "⌃J ⌃K move".
  @movement_hint ~r/"[^"\n]*(?:\bj k\b|⌃J ⌃K|⌃J\/⌃K)[^"\n]*move[^"\n]*"/

  test "neither frontend's picker code spells movement keys into its hints" do
    for source <- @picker_sources do
      text = File.read!(Path.join(@root, source))

      assert Regex.scan(@movement_hint, text) == [],
             "#{source} spells movement keys into hint text; draw the hints the BEAM sends instead"
    end
  end
end
