defmodule AuthApp.Repo do
  use Ecto.Repo,
    otp_app: :auth_app,
    adapter: Ecto.Adapters.SQLite3
end
