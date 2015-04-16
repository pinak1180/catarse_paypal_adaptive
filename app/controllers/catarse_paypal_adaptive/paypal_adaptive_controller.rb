class CatarsePaypalAdaptive::PaypalAdaptiveController < ApplicationController
  include PayPal::SDK::AdaptivePayments

  skip_before_filter :force_http
  skip_before_filter :verify_authenticity_token, :only => [:ipn]

  SCOPE = "projects.contributions.checkout"
  layout :false

  def ipn
    if PayPal::SDK::Core::API::IPN.valid?(request.raw_post) && (contribution.payment_method == 'PayPal' || contribution.payment_method.nil?)
      process_paypal_message params
      contribution.update_attributes(:payment_service_fee => params['mc_fee'], :payer_email => params['payer_email'])
    else
      return render status: 500, nothing: true
    end
    return render status: 200, nothing: true
  rescue Exception => e
    Rails.logger.info "-----> #{e.inspect}"
    return render status: 500, text: e.inspect
  end

  def pay
    begin
      @pay = api.build_pay({
        :actionType => "PAY",
        :cancelUrl => cancel_paypal_adaptive_url(id: contribution.id),
        :currencyCode => "USD",
        :feesPayer => "PRIMARYRECEIVER",
        :ipnNotificationUrl => ipn_paypal_adaptive_index_url(subdomain: 'www'),
        :receiverList => {
          :receiver => [{
            :amount =>9.5,
            :email => contribution.project.user.email,:primary => true  },
            {
              :amount => 0.5,
              :email =>  "paypal@contribute.de",:primary => false }],
            },
        :returnUrl => success_paypal_adaptive_url(id: contribution.id) })

      response = api.pay(@pay) if request.post?

      PaymentEngines.create_payment_notification contribution_id: contribution.id, extra_data: response.to_hash

      if response.success? && response.payment_exec_status != "ERROR"
        contribution.update_attributes payment_method: 'PayPal', payment_token: response.payKey
        redirect_to api.payment_url(response)  # Url to complete payment
      else
        Rails.logger.info "----pinak-> #{response.error}"
        flash[:failure] = t('paypal_error', scope: SCOPE)
        return redirect_to main_app.new_project_contribution_path(contribution.project)
      end

    rescue Exception => e
      Rails.logger.info "--shreya---> #{e.inspect}"
      puts e.message
      flash[:failure] = t('paypal_error', scope: SCOPE)
      return redirect_to main_app.new_project_contribution_path(contribution.project)
    end
  end

  def success
    begin
      payment_details = api.build_payment_details(:payKey => contribution.payment_token)
      response = api.payment_details(payment_details)

      PaymentEngines.create_payment_notification contribution_id: contribution.id, extra_data: response.to_hash

      if response.success? && response.status == 'COMPLETED'
        # contribution.update_attributes payment_id: purchase.params['transaction_id'] if purchase.params['transaction_id']
        contribution.confirm!

        flash[:success] = t('success', scope: SCOPE)
        redirect_to main_app.project_contribution_path(project_id: contribution.project.id, id: contribution.id)
      else
        flash[:failure] = t('paypal_error', scope: SCOPE)
        redirect_to main_app.new_project_contribution_path(contribution.project)
      end
    rescue Exception => e
      Rails.logger.info "-----> #{e.inspect}"
      flash[:failure] = t('paypal_error', scope: SCOPE)
      return redirect_to main_app.new_project_contribution_path(contribution.project)
    end
  end

  def cancel
    contribution.cancel!
    flash[:failure] = t('paypal_cancel', scope: SCOPE)
    redirect_to main_app.new_project_contribution_path(contribution.project)
  end

  def contribution
    @contribution ||= if params['id']
                  PaymentEngines.find_payment(id: params['id'])
                elsif params['txn_id']
                  PaymentEngines.find_payment(payment_id: params['txn_id']) || (params['parent_txn_id'] && PaymentEngines.find_payment(payment_id: params['parent_txn_id']))
                elsif params['pay_key']
                  PaymentEngines.find_payment(payment_token: params['pay_key'])
                end
  end

  def process_paypal_message(data)
    extra_data = (data['charset'] ? JSON.parse(data.to_json.force_encoding(data['charset']).encode('utf-8')) : data)
    PaymentEngines.create_payment_notification contribution_id: contribution.id, extra_data: extra_data

    if data["checkout_status"] == 'PaymentActionCompleted'
      contribution.confirm!
    elsif data["status"]
      case data["status"].downcase
      when 'completed'
        contribution.confirm!
      when 'refunded'
        contribution.refund!
      when 'canceled_reversal'
        contribution.cancel!
      when 'expired', 'denied'
        contribution.pendent!
      else
        contribution.waiting! if contribution.pending?
      end
    end
  end



  private

  def api
    @api ||= API.new
  end

end
