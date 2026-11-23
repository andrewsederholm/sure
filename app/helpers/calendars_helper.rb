module CalendarsHelper
  def calendar_nav_item
    {
      name: t("calendars.nav"),
      path: calendar_path,
      icon: "calendar-days",
      icon_custom: false,
      active: page_active?(calendar_path)
    }
  end

  # Month links keep the layer switches as they are.
  def calendar_month_path(month = nil)
    layer_params = CalendarsController::LAYERS.index_with { |layer| @layers.include?(layer) ? "1" : "0" }
    calendar_path(layer_params.merge(month: month&.strftime("%Y-%m")).compact)
  end

  # Income green, spending plain, net coloured by sign, as on Transactions.
  def calendar_net_class(money)
    if money.positive?
      "text-success"
    elsif money.negative?
      "text-primary"
    else
      "text-secondary"
    end
  end
end
