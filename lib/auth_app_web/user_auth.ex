defmodule AuthAppWeb.UserAuth do
  use AuthAppWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias AuthApp.Accounts

  # Make the remember me cookie valid for 60 days.
  # If you want bump or reduce this value, also change
  # the token expiry itself in UserToken.
  @max_age 60 * 60 * 24 * 60
  @remember_me_cookie "_auth_app_web_user_remember_me"
  @remember_me_options [sign: true, max_age: @max_age, same_site: "Lax"]

  @doc """
  Logs the user in.

  It renews the session ID and clears the whole session
  to avoid fixation attacks. See the renew_session
  function to customize this behaviour.

  It also sets a `:live_socket_id` key in the session,
  so LiveView sessions are identified and automatically
  disconnected on log out. The line can be safely removed
  if you are not using LiveView.

  In case the user re-authenticates for sudo mode,
  the existing remember_me setting is kept, writing a new remember_me cookie.
  """

  def log_in_user(conn_or_socket, user, params \\ %{})

  def log_in_user(%Phoenix.LiveView.Socket{} = socket, user, params) do
    token = Accounts.generate_user_session_token(user)
    user_return_to = Phoenix.LiveView.get_session(socket, :user_return_to)
    remember_me = Phoenix.LiveView.get_session(socket, :user_remember_me)

    socket
    |> renew_session()
    |> put_token_in_session(token)
    # |> maybe_write_remember_me_cookie(token, params, remember_me)
    |> Phoenix.LiveView.redirect(to: user_return_to || signed_in_path(socket))
  end

  # defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
  #   do: write_remember_me_cookie(conn, token)

  # defp maybe_write_remember_me_cookie(conn, token, _params, true),
  #   do: write_remember_me_cookie(conn, token)

  # defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  # defp write_remember_me_cookie(conn, token) do
  #   conn
  #   |> put_session(:user_remember_me, true)
  #   |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  # end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn) do
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  defp renew_session(%Plug.Conn{} = conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp renew_session(%Phoenix.LiveView.Socket{} = socket) do
    # delete_csrf_token()

    socket
    |> Phoenix.LiveView.configure_session(renew: true)
    |> Phoenix.LiveView.clear_session()
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(%Phoenix.LiveView.Socket{} = socket) do
    user_token = Phoenix.LiveView.get_session(socket, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = Phoenix.LiveView.get_session(socket, :live_socket_id) do
      AuthAppWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    socket
    |> renew_session()
    # |> delete_resp_cookie(@remember_me_cookie)
    |> Phoenix.LiveView.redirect(to: ~p"/")
  end

  def log_out_user(%Plug.Conn{} = conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      AuthAppWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    # |> delete_resp_cookie(@remember_me_cookie)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by looking into the session
  and remember me token.
  """
  def fetch_current_user(conn, _opts) do
    {user_token, conn} = ensure_user_token(conn)
    user = user_token && Accounts.get_user_by_session_token(user_token)
    assign(conn, :current_user, user)
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, put_token_in_session(conn, token)}
      else
        {nil, conn}
      end
    end
  end

  @doc """
  Handles mounting and authenticating the current_user in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_user` - Assigns current_user
      to socket assigns based on user_token, or nil if
      there's no user_token or no matching user.

    * `:ensure_authenticated` - Authenticates the user from the session,
      and assigns the current_user to socket assigns based
      on user_token.
      Redirects to login page if there's no logged user.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the current_user:

      defmodule AuthAppWeb.PageLive do
        use AuthAppWeb, :live_view

        on_mount {AuthAppWeb.UserAuth, :mount_current_user}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{AuthAppWeb.UserAuth, :ensure_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  def on_mount(:ensure_sudo_mode, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if Accounts.sudo_mode?(socket.assigns.current_user, -10) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must re-authenticate to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  defp mount_current_user(socket, session) do
    Phoenix.Component.assign_new(socket, :current_user, fn ->
      if user_token = session["user_token"] do
        Accounts.get_user_by_session_token(user_token)
      end
    end)
  end

  @doc """
  Used for routes that require the user to be authenticated.

  If you want to enforce the user email is confirmed before
  they use the application at all, here would be a good place.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  defp put_token_in_session(%Phoenix.LiveView.Socket{} = socket, token) do
    socket
    |> Phoenix.LiveView.put_session(:user_token, token)
    |> Phoenix.LiveView.put_session(:live_socket_id, user_session_topic(token))
  end

  defp put_token_in_session(%Plug.Conn{} = conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      AuthAppWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  @doc "Returns the path to redirect to after log in."
  # the user was already logged in, redirect to settings
  def signed_in_path(%Plug.Conn{assigns: %{current_user: %Accounts.User{}}}) do
    ~p"/users/settings"
  end

  def signed_in_path(_), do: ~p"/"
end
