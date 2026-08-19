import Config

config :git_hooks, auto_install: false

if config_env() == :dev do
  config :git_hooks,
    auto_install: false,
    verbose: true,
    hooks: [
      commit_msg: [
        tasks: [
          {:cmd, "mix git_ops.check_message", include_hook_args: true}
        ]
      ]
    ]

  config :git_ops,
    mix_project: Jido.Chat.Teams.MixProject,
    repository_url: "https://github.com/agentjido/jido_chat_teams",
    manage_mix_version?: true,
    version_tag_prefix: "v"
end

if File.exists?(Path.expand("#{config_env()}.exs", __DIR__)) do
  import_config "#{config_env()}.exs"
end
