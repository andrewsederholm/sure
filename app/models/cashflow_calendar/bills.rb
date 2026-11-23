# The Calendar page's Bills layer: the same occurrences the Bills calendar
# shows (BillsController#load_calendar), so a chip here means the same thing
# and opens the same drawer. Payable series the user can reach, due in the
# range, with paid amounts preloaded for the chip's state colour.
class CashflowCalendar::Bills
  # Occurrences are generated on demand; the Bills calendar stops at 13
  # months out, so this layer does too.
  FORWARD_LIMIT_MONTHS = 13
  # Rows already exist this far out; past it, generate before reading.
  MATERIALIZED_DAYS = 89

  def initialize(family, user:, start_date:, end_date:)
    @family = family
    @user = user
    @start_date = start_date
    @end_date = end_date
  end

  def by_day
    @by_day ||= begin
      materialize_through(end_date) if end_date > Date.current + MATERIALIZED_DAYS

      occurrences = family.recurring_occurrences
                          .where(recurring_transaction_id: series_ids)
                          .due_between(start_date, end_date)
                          .includes(recurring_transaction: { merchant: { logo_attachment: :blob } })
                          .to_a
      RecurringOccurrence.preload_confirmed_allocated(occurrences)

      occurrences.group_by(&:due_on)
    end
  end

  def on(date)
    (by_day[date] || []).sort_by { |occurrence| -occurrence.resolved_expected_amount }
  end

  private
    attr_reader :family, :user, :start_date, :end_date

    def series_ids
      family.recurring_transactions
            .where(status: %w[active inactive])
            .obligations(%w[CreditCard Loan])
            .accessible_by(user)
            .select(:id)
    end

    def materialize_through(date)
      limit = (Date.current + FORWARD_LIMIT_MONTHS.months).end_of_month
      through = [ date, limit ].min

      family.recurring_transactions.active.where(id: series_ids).find_each do |series|
        RecurringTransaction::OccurrenceGenerator.new(series).generate!(through: through)
      end
    end
end
