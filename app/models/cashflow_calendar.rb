# The money that moved each day across a date range, for the Calendar page.
#
# Built on Transaction::Search so account access, split handling and inactive
# accounts match the Transactions list. Unlike the Transactions totals,
# transfers count toward a day's in and out (each leg on its own side), because
# the question here is "what moved on the 14th", not "what did I earn".
# Excluded entries and tax-advantaged accounts stay out, as they do there.
#
# Pending covers both bank-pending rows and future-dated (scheduled) ones:
# either way the money hasn't settled yet. Pending amounts are part of the
# day's totals and also reported on their own so the UI can mark them.
class CashflowCalendar
  Day = Data.define(:date, :income, :spending, :pending_income, :pending_spending, :count, :pending_count) do
    def self.empty(date, currency)
      zero = Money.new(0, currency)
      new(date:, income: zero, spending: zero, pending_income: zero, pending_spending: zero, count: 0, pending_count: 0)
    end

    def net
      income - spending
    end

    def empty?
      count.zero?
    end

    def pending?
      pending_count.positive?
    end

    def all_pending?
      count.positive? && pending_count == count
    end
  end

  attr_reader :family, :start_date, :end_date

  def initialize(family, start_date:, end_date:, accessible_account_ids:)
    @family = family
    @start_date = start_date
    @end_date = end_date
    @accessible_account_ids = accessible_account_ids
  end

  def day(date)
    days.fetch(date) { Day.empty(date, currency) }
  end

  # Days that had at least one transaction, keyed by date.
  def days
    @days ||= build_days
  end

  # Transactions in the range whose currency has no stored rate into the
  # family currency. They're counted on their day but their amounts are
  # left out, as on the Transactions page.
  def unconvertible_count
    days && @unconvertible_count
  end

  def totals_for(range)
    in_range = days.values.select { |day| range.cover?(day.date) }
    zero = Money.new(0, currency)
    income = in_range.sum(zero, &:income)
    spending = in_range.sum(zero, &:spending)
    { income:, spending:, net: income - spending }
  end

  private
    attr_reader :accessible_account_ids

    def currency
      family.currency
    end

    def build_days
      @unconvertible_count = 0

      rows.each_with_object({}) do |row, by_date|
        date, pending, income, spending, count, unconvertible = row
        @unconvertible_count += unconvertible.to_i

        day = by_date[date] || Day.empty(date, currency)
        income_money = Money.new(income || 0, currency)
        spending_money = Money.new(spending || 0, currency)

        by_date[date] = day.with(
          income: day.income + income_money,
          spending: day.spending + spending_money,
          pending_income: pending ? day.pending_income + income_money : day.pending_income,
          pending_spending: pending ? day.pending_spending + spending_money : day.pending_spending,
          count: day.count + count.to_i,
          pending_count: pending ? day.pending_count + count.to_i : day.pending_count
        )
      end
    end

    # One grouped query for the whole range: a row per (date, pending) pair.
    def rows
      rate = ExchangeRate.rate_sql(from: "entries.currency", to: ":currency", on: "entries.date")
      binds = { currency: currency, today: Date.current }
      pending = sql([ "(#{Transaction.pending_sql} OR entries.date > :today)", binds ])

      scope.group(Arel.sql("entries.date"), pending).pluck(
        Arel.sql("entries.date"),
        pending,
        sql([ "SUM(CASE WHEN entries.amount < 0 THEN -entries.amount * #{rate} ELSE 0 END)", binds ]),
        sql([ "SUM(CASE WHEN entries.amount > 0 THEN entries.amount * #{rate} ELSE 0 END)", binds ]),
        Arel.sql("COUNT(entries.id)"),
        sql([ "COUNT(entries.id) FILTER (WHERE (#{rate}) IS NULL)", binds ])
      )
    end

    def sql(fragment_with_binds)
      Arel.sql(ActiveRecord::Base.sanitize_sql_array(fragment_with_binds))
    end

    def scope
      search = Transaction::Search.new(
        family,
        filters: { start_date: start_date.to_s, end_date: end_date.to_s },
        accessible_account_ids: accessible_account_ids
      )

      query = search.transactions_scope.where(entries: { excluded: false })
      tax_advantaged_ids = family.tax_advantaged_account_ids
      query = query.where.not(accounts: { id: tax_advantaged_ids }) if tax_advantaged_ids.present?
      query
    end
end
