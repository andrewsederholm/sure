require "test_helper"

class CalendarsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @family.accounts.each { |account| account.entries.delete_all }
    @family.recurring_transactions.destroy_all
    @checking = accounts(:depository)
    ensure_tailwind_build
  end

  test "renders the current month for every user, without preview features" do
    set_preview(false)

    get calendar_url

    assert_response :success
    assert_select "h1", text: "Calendar"
    assert_match Date.current.strftime("%B %Y"), response.body
  end

  test "is reachable from the main nav" do
    get calendar_url

    assert_select "a[href='#{calendar_path}']"
  end

  test "shows the month's in, out and net, with amounts privacy-marked" do
    create_transaction(account: @checking, date: Date.current, amount: -1000, kind: "standard")
    create_transaction(account: @checking, date: Date.current, amount: 250, kind: "standard")

    get calendar_url

    assert_select ".privacy-sensitive", text: "$1,000.00"
    assert_select ".privacy-sensitive", text: "$250.00"
    assert_select ".privacy-sensitive", text: "$750.00"
  end

  test "each day links to its drawer" do
    get calendar_url

    assert_select "a[data-turbo-frame=drawer][href='#{calendar_day_path(date: Date.current.iso8601)}']", minimum: 1
  end

  test "navigates to another month" do
    get calendar_url(month: "2025-02")

    assert_response :success
    assert_match "February 2025", response.body
  end

  test "falls back to the current month for a bad month param" do
    get calendar_url(month: "nope")

    assert_response :success
    assert_match Date.current.strftime("%B %Y"), response.body
  end

  test "the transactions layer can be turned off" do
    create_transaction(account: @checking, date: Date.current, amount: 250, kind: "standard")

    get calendar_url(transactions: "0")

    assert_response :success
    assert_no_match "$250.00", response.body
    assert_select "input#calendar_layer_transactions:not([checked])"
  end

  test "month links keep the layer switches" do
    get calendar_url(transactions: "0", month: "2025-02")

    assert_select "a[href*='month=2025-03'][href*='transactions=0']"
  end

  test "hides the bills layer and its switch without preview features" do
    set_preview(false)
    create_bill(name: "Rent", amount: 900)

    get calendar_url

    assert_select "input#calendar_layer_bills", count: 0
    assert_no_match "Rent", response.body
  end

  test "shows bill chips with preview features" do
    set_preview(true)
    create_bill(name: "Rent", amount: 900)

    get calendar_url

    assert_select "input#calendar_layer_bills[checked]"
    assert_match "Rent", response.body
  end

  test "the bills layer can be turned off" do
    set_preview(true)
    create_bill(name: "Rent", amount: 900)

    get calendar_url(bills: "0")

    assert_no_match "Rent", response.body
  end

  test "hides the bills layer when recurring detection is off" do
    set_preview(true)
    create_bill(name: "Rent", amount: 900)
    @family.update!(recurring_transactions_disabled: true)

    get calendar_url

    assert_select "input#calendar_layer_bills", count: 0
  end

  test "the day drawer lists exactly that day's transactions" do
    day = Date.current - 3.days
    create_transaction(account: @checking, date: day, amount: 42, name: "Groceries", kind: "standard")
    create_transaction(account: @checking, date: day + 1.day, amount: 17, name: "Next day coffee", kind: "standard")

    get calendar_day_url(date: day.iso8601)

    assert_response :success
    assert_select "turbo-frame#drawer"
    assert_match "Groceries", response.body
    assert_no_match "Next day coffee", response.body
    assert_select ".privacy-sensitive", text: "-$42.00"
  end

  test "the day drawer marks pending transactions" do
    pending = create_transaction(account: @checking, date: Date.current, amount: 30, name: "Pending charge", kind: "standard")
    pending.entryable.update!(extra: { "simplefin" => { "pending" => true } })

    get calendar_day_url(date: Date.current.iso8601)

    assert_match "Pending charge", response.body
    assert_match I18n.t("transactions.transaction.pending"), response.body
  end

  test "the day drawer links to the filtered transactions list" do
    day = Date.current - 1.day

    get calendar_day_url(date: day.iso8601)

    assert_select "a[href='#{transactions_path(q: { start_date: day.iso8601, end_date: day.iso8601 })}']"
  end

  test "the day drawer leaves out accounts the user cannot access" do
    member = users(:family_member)
    sign_in member
    hidden_account = @family.accounts.where.not(id: member.accessible_accounts.select(:id)).first
    skip "fixtures give the member access to every account" unless hidden_account

    create_transaction(account: hidden_account, date: Date.current, amount: 12, name: "Not yours", kind: "standard")

    get calendar_day_url(date: Date.current.iso8601)

    assert_no_match "Not yours", response.body
  end

  test "an invalid date redirects to the calendar" do
    get "/calendar/days/2025-02-30"

    assert_redirected_to calendar_path
  end

  private
    def set_preview(enabled)
      @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => enabled))
    end

    def create_bill(name:, amount:)
      @family.recurring_transactions.create!(
        account: @checking,
        name: name,
        amount: amount,
        dedup_scope: amount.to_s,
        currency: "USD",
        expected_day_of_month: Date.current.day,
        last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: Date.current,
        status: "active"
      )
    end
end
