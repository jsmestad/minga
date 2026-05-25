import Config

config_path = Path.expand("#{config_env()}.exs", __DIR__)

if File.exists?(config_path) do
  import_config config_path
end
