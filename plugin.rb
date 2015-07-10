# name: df-paid-membership
# about: You can automatically sell membership in particular user groups.
# version: 1.0.0
# authors: Dmitry Fedyuk
# url: https://discourse.pro/t/35
require 'paypal'
require 'airbrake'
require 'json'
register_asset 'stylesheets/main.scss'
after_initialize do
	module ::PaidMembership
		class Engine < ::Rails::Engine
			engine_name 'df_paid_membership'
			isolate_namespace PaidMembership
		end
	end
	require_dependency 'application_controller'
	class PaidMembership::IndexController < ::ApplicationController
		skip_before_filter :authorize_mini_profiler,
			:check_xhr,
			:inject_preview_style,
			:preload_json,
			:redirect_to_login_if_required,
			:set_current_user_for_logs,
			:set_locale,
			:set_mobile_view,
			:verify_authenticity_token, only: [:ipn]
		skip_before_filter :authorize_mini_profiler,
			:check_xhr,
			:inject_preview_style,
			:preload_json,
			:redirect_to_login_if_required,
			:set_current_user_for_logs,
			:set_locale,
			:set_mobile_view,
			:verify_authenticity_token, only: [:success]
		protect_from_forgery :except => [:ipn, :success]
		before_filter :paypal_set_sandbox_mode_if_needed, only: [:buy, :ipn, :success]
		def index
			begin
				plans = JSON.parse(SiteSetting.send '«Paid_Membership»_Plans')
			rescue JSON::ParserError => e
				plans = []
			end
			render json: { plans: plans }
		end
		def buy
			Airbrake.notify(
				:error_message => 'Покупка тарифного плана',
				:error_class => 'plans#buy',
				:parameters => params
			)
			plans = JSON.parse(SiteSetting.send '«Paid_Membership»_Plans')
			plan = nil
			planId = params['plan']
			plans.each { |p|
				if planId == p['id']
					plan = p
					break
				end
			}
			tier = nil
			tierId = params['tier']
			puts plan['priceTiers']
			plan['priceTiers'].each { |t|
				if tierId == t['id']
					tier = t
					break
				end
			}
			price = tier['price']
			currency = SiteSetting.send '«PayPal»_Payment_Currency'
			user = User.find_by(id: params['user'])
			paypal_options = {
				no_shipping: true, # if you want to disable shipping information
				allow_note: false, # if you want to disable notes
				pay_on_paypal: true # if you don't plan on showing your own confirmation step
			}
			description =
				"Membership Plan: #{plan['title']}." +
				" User: #{user.username}." +
				" Period: #{tier['period']} #{tier['periodUnits']}."
			paymentId = "#{user.id}::#{planId}::#{tierId}::#{Time.now.strftime("%Y-%m-%d-%H-%M")}"
			paymentRequestParams = {
				:action => 'Sale',
				:currency_code => currency,
				:description => description,
				:quantity => 1,
				:amount => price,
				:notify_url => "#{Discourse.base_url}/plans/ipn",
				:invoice_number => paymentId,
				:custom_fields => {
					#CARTBORDERCOLOR: "C00000",
					#LOGOIMG: "https://example.com/logo.png"
				}
			}
			Airbrake.notify(
				:error_message => 'Регистрация платежа в PayPal',
				:error_class => 'plans#buy',
				:parameters => paymentRequestParams
			)
			payment_request = Paypal::Payment::Request.new paymentRequestParams
			response = paypal_express_request.setup(
				payment_request,
				# после успешной оплаты
				# покупатель будет перенаправлен на свою личную страницу
				"#{Discourse.base_url}/plans/success",
				# в случае неупеха оплаты
				# покупатель будет перенаправлен обратно на страницу с тарифными планами
				"#{Discourse.base_url}/plans",
				paypal_options
			)
			Airbrake.notify(
				:error_message => 'Ответ PayPal на регистрацию',
				:error_class => 'plans#buy',
				:parameters => {redirect_uri: response.redirect_uri}
			)
			render json: { redirect_uri: response.redirect_uri }
		end
		def ipn
			no_cookies
			Airbrake.notify(
				:error_message => 'Оповещение о платеже из PayPal',
				:error_class => 'plans#ipn',
				:parameters => params
			)
			Paypal::IPN.verify!(request.raw_post)
			render :nothing => true
		end
		def success
			Airbrake.notify(
				:error_message => '[success] 1',
				:error_class => 'plans#success',
				:parameters => params
			)
			detailsRequest = paypal_express_request
			details = detailsRequest.details(params['token'])
			Airbrake.notify(
				:error_message => 'details response',
				:parameters => {details: details.inspect}
			)
			payment_request = Paypal::Payment::Request.new({
				:action => 'Sale',
				:currency_code => SiteSetting.send('«PayPal»_Payment_Currency'),
				:amount => details.amount
			})
			response = paypal_express_request.checkout!(
				params['token'],
				params['PayerID'],
				payment_request
			)
			Airbrake.notify(
				:error_message => '[success] payment_request',
				:error_class => 'plans#success',
				:parameters => {payment_request: payment_request.inspect}
			)
			Airbrake.notify(
				:error_message => '[success] response',
				:error_class => 'plans#success',
				:parameters => {response: response.inspect}
			)
			Airbrake.notify(
				:error_message => '[success] response.payment_info',
				:error_class => 'plans#success',
				:parameters => {payment_info: response.payment_info}
			)
			#redirect_to "#{Discourse.base_url}"
			redirect_to "#{Discourse.base_url}/users/#{current_user.username}"
		end
		private
		def paypal_express_request
			prefix = sandbox? ? 'Sandbox_' : ''
			Paypal::Express::Request.new(
				:username => SiteSetting.send("«PayPal»_#{prefix}API_Username"),
				:password => SiteSetting.send("«PayPal»_#{prefix}API_Password"),
				:signature => SiteSetting.send("«PayPal»_#{prefix}Signature")
			)
		end
		def paypal_set_sandbox_mode_if_needed
			if sandbox?
				Paypal.sandbox!
			end
		end
		def sandbox?
			'sandbox' == SiteSetting.send('«PayPal»_Mode')
		end
	end
	PaidMembership::Engine.routes.draw do
		get '/' => 'index#index'
		get '/buy' => 'index#buy'
		get '/ipn' => 'index#ipn'
		get '/success' => 'index#success'
	end
	Discourse::Application.routes.append do
		mount ::PaidMembership::Engine, at: '/plans'
	end
end
