defmodule AuthAppWeb.UserSessionController do
  use AuthAppWeb, :controller

  alias AuthApp.Accounts
  alias AuthAppWeb.UserAuth

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
