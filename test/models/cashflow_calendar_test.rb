require "test_helper"

class CashflowCalendarTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @checking = accounts(:depository)
    @credit_card = accounts(:credit_card)
    @family.accounts.each { |account| account.entries.delete_all }

    @today = Date.current
    @range_start = @today.beginning_of_month - 7.days
    @range_end = @today.end_of_month + 7.days
  end

  test "splits a day's transactions into income and spending, with net" do
    create_transaction(account: @checking, date: @today, amount: -1000, kind: "standard")
    create_transaction(account: @checking, date: @today, amount: 250, kind: "standard")
    create_transaction(account: @checking, date: @today, amount: 50, kind: "standard")

    day = calendar.day(@today)

    assert_equal Money.new(1000, "USD"), day.income
    assert_equal Money.new(300, "USD"), day.spending
    assert_equal Money.new(700, "USD"), day.net
    assert_equal 3, day.count
    assert_not day.pending?
  end

  test "keeps each day separate" do
    yesterday = @today - 1.day
    create_transaction(account: @checking, date: yesterday, amount: 40, kind: "standard")
    create_transaction(account: @checking, date: @today, amount: 60, kind: "standard")

    assert_equal Money.new(40, "USD"), calendar.day(yesterday).spending
    assert_equal Money.new(60, "USD"), calendar.day(@today).spending
    assert_equal [ yesterday, @today ].sort, calendar.days.keys.sort
  end

  test "a day without transactions is empty and zero" do
    day = calendar.day(@today)

    assert day.empty?
    assert_equal Money.new(0, "USD"), day.income
    assert_equal Money.new(0, "USD"), day.net
  end

  test "includes both legs of a transfer" do
    create_transfer(from_account: @checking, to_account: @credit_card, amount: 500, date: @today)

    day = calendar.day(@today)

    assert_equal Money.new(500, "USD"), day.income
    assert_equal Money.new(500, "USD"), day.spending
    assert_equal Money.new(0, "USD"), day.net
    assert_equal 2, day.count
  end

  test "counts pending transactions and reports them separately" do
    create_transaction(account: @checking, date: @today, amount: 100, kind: "standard")
    pending = create_transaction(account: @checking, date: @today, amount: 30, kind: "standard")
    pending.entryable.update!(extra: { "simplefin" => { "pending" => true } })

    day = calendar.day(@today)

    assert_equal Money.new(130, "USD"), day.spending
    assert_equal Money.new(30, "USD"), day.pending_spending
    assert_equal 1, day.pending_count
    assert day.pending?
    assert_not day.all_pending?
  end

  test "treats future-dated transactions as pending" do
    tomorrow = @today + 1.day
    create_transaction(account: @checking, date: tomorrow, amount: -200, kind: "standard")

    day = calendar.day(tomorrow)

    assert_equal Money.new(200, "USD"), day.income
    assert_equal Money.new(200, "USD"), day.pending_income
    assert day.all_pending?
  end

  test "converts other currencies at the day's rate" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @today, rate: 1.1)
    create_transaction(account: @checking, date: @today, amount: 100, currency: "EUR", kind: "standard")
    create_transaction(account: @checking, date: @today, amount: 50, currency: "USD", kind: "standard")

    assert_equal Money.new(160, "USD"), calendar.day(@today).spending
    assert_equal 0, calendar.unconvertible_count
  end

  test "leaves out amounts with no exchange rate but still counts them" do
    create_transaction(account: @checking, date: @today, amount: 100, currency: "KRW", kind: "standard")
    create_transaction(account: @checking, date: @today, amount: 20, kind: "standard")

    day = calendar.day(@today)

    assert_equal Money.new(20, "USD"), day.spending
    assert_equal 2, day.count
    assert_equal 1, calendar.unconvertible_count
  end

  test "leaves out excluded transactions" do
    create_transaction(account: @checking, date: @today, amount: 75, kind: "standard", excluded: true)

    assert calendar.day(@today).empty?
  end

  test "only includes accounts the user can access" do
    create_transaction(account: @checking, date: @today, amount: 10, kind: "standard")
    create_transaction(account: @credit_card, date: @today, amount: 90, kind: "standard")

    day = calendar(accessible_account_ids: [ @checking.id ]).day(@today)

    assert_equal Money.new(10, "USD"), day.spending
    assert_equal 1, day.count
  end

  test "ignores transactions outside the range" do
    create_transaction(account: @checking, date: @range_start - 1.day, amount: 10, kind: "standard")

    assert_empty calendar.days
  end

  test "totals a sub-range such as the visible month" do
    first = @today.beginning_of_month
    create_transaction(account: @checking, date: first, amount: -500, kind: "standard")
    create_transaction(account: @checking, date: first, amount: 120, kind: "standard")
    create_transaction(account: @checking, date: first - 1.day, amount: 999, kind: "standard")

    totals = calendar.totals_for(first..@today.end_of_month)

    assert_equal Money.new(500, "USD"), totals[:income]
    assert_equal Money.new(120, "USD"), totals[:spending]
    assert_equal Money.new(380, "USD"), totals[:net]
  end

  test "reads every day of the range from one entries query" do
    5.times { |offset| create_transaction(account: @checking, date: @today - offset.days, amount: 10, kind: "standard") }
    cal = calendar

    assert_equal 1, count_entries_queries { cal.days }
    assert_equal 5, cal.days.size
  end

  private
    def calendar(accessible_account_ids: @family.accounts.pluck(:id))
      CashflowCalendar.new(@family, start_date: @range_start, end_date: @range_end, accessible_account_ids: accessible_account_ids)
    end

    # Account lookups (tax-advantaged ids) are fixed per family; only reads of
    # entries could grow with the number of days.
    def count_entries_queries(&block)
      count = 0
      counter = ->(*, payload) { count += 1 if !payload[:cached] && payload[:sql].match?(/\bentries\b/) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end
end
