module Jobs
  module Cron
    class PaymentAddressBalancer
      def self.process
        PaymentAddress.where.not(address: nil).find_each(&method(:update_balances))
        sleep 10
      end

      def self.update_balances payment_address
        if payment_address.blockchain.gateway_class.enable_personal_address_balance?
          return unless payment_address.blockchain.active?
          payment_address.update!(
            balances: convert_balances(payment_address.blockchain.gateway.load_balances(payment_address.address)),
            balances_updated_at: Time.zone.now
          )
        else
          payment_address.update! balances: {}, balances_updated_at: Time.zone.now
        end
      rescue StandardError => err
        Rails.logger.warn "#{err} for payment_address id #{payment_address.id}"
        report_exception err, true, payment_address_id: payment_address.id
      end

      def self.convert_balances(balances)
        balances.each_with_object({}) do |(k,v), a|
          currency_id = (k.is_a?(Money::Currency) || k.is_a?(Currency)) ? k.id.downcase : k
          a[currency_id] = v.to_d
        end.select { |_k, v| v.positive? }
      end
    end
  end
end
