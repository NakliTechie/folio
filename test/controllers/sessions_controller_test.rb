require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = User.take }

  test "new" do
    get new_session_path
    assert_response :success
  end

  test "create with valid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "password" }

    assert_redirected_to root_path
    assert cookies[:session_id]
  end

  test "create with invalid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "wrong" }

    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]
  end

  test "destroy" do
    sign_in_as(User.take)

    delete session_path

    assert_redirected_to new_session_path
    assert_empty cookies[:session_id]
  end

  test "an idle session is destroyed and must authenticate again" do
    sign_in_as(@user)
    expired_session = Current.session
    expired_session.update!(last_seen_at: 2.hours.ago)
    Current.session = nil

    get root_path

    assert_redirected_to new_session_path
    assert_not Session.exists?(expired_session.id)
    assert_empty cookies[:session_id]
  end
end
