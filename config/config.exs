import Config

# Import environment-specific config at the bottom so it can
# override values set above.
import_config "#{config_env()}.exs"
