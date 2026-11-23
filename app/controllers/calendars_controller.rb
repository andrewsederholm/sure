# The cash-flow calendar: a month grid of what came in and went out each day,
# with the Bills calendar's chips as an optional second layer, and a drawer
# listing one day's transactions.
class CalendarsController < ApplicationController
  LAYERS = %w[transactions bills].freeze

  def show
    today = Date.current
    @month = parse_month || today.beginning_of_month
    @grid_start = @month.beginning_of_week(:sunday)
    @grid_end = @month.end_of_month.end_of_week(:sunday)

    @bills_available = bills_available?
    @layers = selected_layers

    if @layers.include?("transactions")
      @cashflow = CashflowCalendar.new(
        Current.family,
        start_date: @grid_start,
        end_date: @grid_end,
        accessible_account_ids: accessible_account_ids
      )
      @month_totals = @cashflow.totals_for(@month..@month.end_of_month)
    end

    if @layers.include?("bills")
      @bills = CashflowCalendar::Bills.new(Current.family, user: Current.user, start_date: @grid_start, end_date: @grid_end)
    end
  end

  def day
    @date = Date.iso8601(params[:date])
    @summary = CashflowCalendar.new(Current.family, start_date: @date, end_date: @date, accessible_account_ids: accessible_account_ids).day(@date)

    search = Transaction::Search.new(
      Current.family,
      filters: { start_date: @date.to_s, end_date: @date.to_s },
      accessible_account_ids: accessible_account_ids
    )
    @transactions = search.transactions_scope
                          .reverse_chronological
                          .includes({ entry: :account }, :category, { merchant: { logo_attachment: :blob } })
                          .to_a
  rescue Date::Error
    redirect_to calendar_path
  end

  private
    def parse_month
      Date.strptime(params[:month].to_s, "%Y-%m").beginning_of_month
    rescue ArgumentError
      nil
    end

    def accessible_account_ids
      @accessible_account_ids ||= Current.user.accessible_accounts.pluck(:id)
    end

    # Bills is a preview surface that only exists while recurring detection is
    # on; without both, its chips would lead to pages that redirect away.
    def bills_available?
      preview_features_enabled? && !Current.family.recurring_transactions_disabled?
    end

    # Each layer is on unless its param says "0", so a bare /calendar shows
    # everything. The toggles submit "0"/"1" for both, and links carry them on.
    def selected_layers
      available = @bills_available ? LAYERS : LAYERS - [ "bills" ]
      available.reject { |layer| params[layer] == "0" }
    end
end
