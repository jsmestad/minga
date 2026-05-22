defmodule MingaEditor.UI.Theme.UserRegistrationTest do
  @moduledoc "Tests for runtime user theme registration. async: false because persistent_term is global."
  use ExUnit.Case, async: false

  alias MingaEditor.UI.Theme

  setup do
    on_exit(fn ->
      Theme.unregister_source({:extension, :theme_registration_test})
      Theme.unregister_source({:extension, :theme_registration_other})
      Theme.register_user_themes(%{})
    end)

    :ok
  end

  test "register_user_themes makes themes available via get/1" do
    doom = Theme.get!(:doom_one)

    loaded = %MingaEditor.UI.Theme.Loader.LoadedTheme{
      name: :test_user_theme,
      theme: %{doom | name: :test_user_theme},
      face_registry: MingaEditor.UI.Face.Registry.from_theme(doom),
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

    loaded = %MingaEditor.UI.Theme.Loader.LoadedTheme{
      name: :doom_one,
      theme: custom,
      face_registry: MingaEditor.UI.Face.Registry.from_theme(custom),
      source_path: "/tmp/doom_one.exs"
    }

    Theme.register_user_themes(%{doom_one: loaded})
    {:ok, theme} = Theme.get(:doom_one)
    assert theme.editor.fg == 0x123456
  end

  test "same-source theme replacement keeps the latest value" do
    source = {:extension, :theme_registration_test}
    doom = Theme.get!(:doom_one)

    first = %{doom | name: :shared_extension_theme, editor: %{doom.editor | fg: 0x111111}}
    second = %{doom | name: :shared_extension_theme, editor: %{doom.editor | fg: 0x222222}}

    assert :ok = Theme.register_themes(%{shared_extension_theme: first}, source)
    assert :ok = Theme.register_themes(%{shared_extension_theme: second}, source)

    assert {:ok, %Theme{name: :shared_extension_theme, editor: %{fg: 0x222222}}} =
             Theme.get(:shared_extension_theme)
  end

  test "rejects duplicate theme names from different sources" do
    source_a = {:extension, :theme_registration_test}
    source_b = {:extension, :theme_registration_other}
    doom = Theme.get!(:doom_one)

    first = %{doom | name: :duplicate_extension_theme, editor: %{doom.editor | fg: 0x333333}}
    second = %{doom | name: :duplicate_extension_theme, editor: %{doom.editor | fg: 0x444444}}

    assert :ok = Theme.register_themes(%{duplicate_extension_theme: first}, source_a)

    assert {:error, {:duplicate_name, :duplicate_extension_theme, ^source_a, ^source_b}} =
             Theme.register_themes(%{duplicate_extension_theme: second}, source_b)

    assert {:ok, %Theme{name: :duplicate_extension_theme, editor: %{fg: 0x333333}}} =
             Theme.get(:duplicate_extension_theme)
  end

  test "unregister_source removes only themes owned by that source and keeps built-in fallback" do
    doom = Theme.get!(:doom_one)
    source = {:extension, :theme_registration_test}
    other_source = {:extension, :theme_registration_other}

    Theme.register_themes(%{extension_theme: %{doom | name: :extension_theme}}, source)

    Theme.register_themes(
      %{other_extension_theme: %{doom | name: :other_extension_theme}},
      other_source
    )

    assert {:ok, %Theme{name: :extension_theme}} = Theme.get(:extension_theme)
    assert :ok = Theme.unregister_source(source)

    assert :error = Theme.get(:extension_theme)
    assert {:ok, %Theme{name: :other_extension_theme}} = Theme.get(:other_extension_theme)
    assert {:ok, %Theme{name: :doom_one}} = Theme.get(:doom_one)
  end

  test "registering empty map clears user themes" do
    doom = Theme.get!(:doom_one)

    loaded = %MingaEditor.UI.Theme.Loader.LoadedTheme{
      name: :ephemeral_theme,
      theme: %{doom | name: :ephemeral_theme},
      face_registry: MingaEditor.UI.Face.Registry.from_theme(doom),
      source_path: "/tmp/ephemeral.exs"
    }

    Theme.register_user_themes(%{ephemeral_theme: loaded})
    assert {:ok, _} = Theme.get(:ephemeral_theme)

    Theme.register_user_themes(%{})
    assert :error = Theme.get(:ephemeral_theme)
  end
end
