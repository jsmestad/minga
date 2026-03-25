defmodule Minga.UI.Theme.UserRegistrationTest do
  @moduledoc "Tests for runtime user theme registration. async: false because persistent_term is global."
  use ExUnit.Case, async: false

  alias Minga.UI.Theme

  setup do
    on_exit(fn -> Theme.register_user_themes(%{}) end)
    :ok
  end

  test "register_user_themes makes themes available via get/1" do
    doom = Theme.get!(:doom_one)

    loaded = %Minga.UI.Theme.Loader.LoadedTheme{
      name: :test_user_theme,
      theme: %{doom | name: :test_user_theme},
      face_registry: Minga.UI.Face.Registry.from_theme(doom),
      source_path: "/tmp/test.exs"
    }

    Theme.register_user_themes(%{test_user_theme: loaded})

    assert {:ok, theme} = Theme.get(:test_user_theme)
    assert theme.name == :test_user_theme
    assert :test_user_theme in Theme.available()
  end

  test "user themes take precedence over built-in" do
    doom = Theme.get!(:doom_one)
    custom = %{doom | name: :doom_one, editor: %{doom.editor | fg: 0x123456}}

    loaded = %Minga.UI.Theme.Loader.LoadedTheme{
      name: :doom_one,
      theme: custom,
      face_registry: Minga.UI.Face.Registry.from_theme(custom),
      source_path: "/tmp/doom_one.exs"
    }

    Theme.register_user_themes(%{doom_one: loaded})
    {:ok, theme} = Theme.get(:doom_one)
    assert theme.editor.fg == 0x123456
  end

  test "registering empty map clears user themes" do
    doom = Theme.get!(:doom_one)

    loaded = %Minga.UI.Theme.Loader.LoadedTheme{
      name: :ephemeral_theme,
      theme: %{doom | name: :ephemeral_theme},
      face_registry: Minga.UI.Face.Registry.from_theme(doom),
      source_path: "/tmp/ephemeral.exs"
    }

    Theme.register_user_themes(%{ephemeral_theme: loaded})
    assert {:ok, _} = Theme.get(:ephemeral_theme)

    Theme.register_user_themes(%{})
    assert :error = Theme.get(:ephemeral_theme)
  end
end
