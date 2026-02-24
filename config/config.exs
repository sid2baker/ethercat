import Config

# VintageNet passive mode — observe interfaces without managing them.
# On Nerves, override these in config/target.exs with real settings.
config :vintage_net,
  resolvconf: "/dev/null",
  persistence: VintageNet.Persistence.Null,
  config: []
