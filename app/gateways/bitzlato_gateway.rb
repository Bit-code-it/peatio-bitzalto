# frozen_string_literal: true

require 'peatio/bitzlato/wallet'

# rubocop:disable Lint/UnusedMethodArgument
class BitzlatoGateway < AbstractGateway
  def self.enable_personal_address_balance?
    false
  end

  def self.valid_address?(address)
    is_bitcoin_address = BitcoinGateway.valid_address?(address)
    is_bitzlato_address = address =~ /^[a-zA-Z0-9_]{2,15}$/i
    !is_bitcoin_address && is_bitzlato_address
  end

  def load_balance(_address, currency)
    client.load_balance(currency.id).tap do |amount|
      currency.to_money_from_decimal amount
    end
  end

  def load_balances
    client.load_balances.each_with_object({}) do |(k, v), a|
      currency = Money::Currency.find k
      if currency.nil?
        logger.debug("Skip not found currency #{k}")
        next
      end
      a[currency] = currency.to_money_from_decimal v
    end
  end

  def poll_deposits!
    client.poll_deposits.each do |intention|
      deposit = Deposit.find_by(currency_id: intention[:currency], invoice_id: intention[:invoice_id])
      if deposit.nil?
        Rails.logger.warn("No such deposit intention ##{intention[:id]} in blockchain #{blockchain.name}")
        next
      end
      deposit.with_lock do
        next if deposit.dispatched?

        unless deposit.amount == intention[:amount]
          report_exception(
            "Deposit and intention amounts are not equeal #{deposit.amount}<>#{intention[:amount]} with intention ##{intention[:id]} in blockchain #{blockchain.name}",
            true,
            deposit_id: deposit.id, deposit_amount: deposit.amount, intention_amount: intention[:amount]
          )
          next
        end
        unless deposit.invoiced? || deposit.submitted?
          report_exception(
            "Deposit #{deposit.id} has skippable status (#{deposit.aasm_state})",
            true,
            deposit_id: deposit.id, deposit_state: deposit.aasm_state, intention: intention.as_json
          )
          next
        end
        deposit.accept!
        deposit.dispatch!

        save_beneficiary deposit, intention[:address]
      end
    end
  end

  def poll_withdraws!
    client.poll_withdraws.each do |withdraw_info|
      next unless withdraw_info.is_done
      next if withdraw_info.withdraw_id.nil?

      withdraw = if withdraw_info.withdraw_id.start_with?('TID')
                   Withdraw.find_by(tid: withdraw_info.withdraw_id)
                 else
                   Withdraw.find_by(id: withdraw_info.withdraw_id)
                 end
      if withdraw.nil?
        Rails.logger.warn("No such withdraw withdraw_info ##{withdraw_info.withdraw_id} in blockchain #{blockchain.name}")
        next
      end
      if withdraw.amount != withdraw_info.amount
        Rails.logger.warn("Withdraw and intention amounts are not equeal #{withdraw.amount}<>#{withdraw_info.amount} with withdraw_info ##{withdraw_info.withdraw_id} in blockchain #{blockchain.name}")
        next
      end
      unless withdraw.confirming?
        Rails.logger.debug { "Withdraw #{withdraw.id} has skippable status (#{withdraw.aasm_state})" }
        next
      end

      Rails.logger.info("Withdraw #{withdraw.id} successed")
      withdraw.success!
    end
  end

  def create_transaction!(to_address:,
                          amount:,
                          from_address: nil,
                          contract_address: nil,
                          gas_factor: nil,
                          nonce: nil,
                          secret: nil,
                          meta: {})
    raise 'amount must be a Money' unless amount.is_a? Money

    client.create_transaction!(
      key: meta.fetch(:withdraw_tid), # It is also posible to use nonce
      to_address: to_address,
      cryptocurrency: amount.currency.id.upcase,
      amount: amount.to_d
    ).dup.tap do |tx|
      tx.currency_id = amount.currency.id
      tx.blockchain_id = blockchain.id
      tx.amount = amount
    end
  end

  def create_invoice!(deposit)
    deposit.with_lock do
      raise "Depost has wrong state #{deposit.aasm_state}. Must be submitted" unless deposit.submitted?

      invoice = client.create_invoice!(
        amount: deposit.amount,
        comment: I18n.t('deposit_comment', account_id: deposit.member.uid, deposit_id: deposit.id, email: deposit.member.email),
        currency_id: deposit.currency_id.to_s.upcase
      )
      deposit.update!(
        data: invoice.slice(:links, :expires_at),
        invoice_id: invoice[:id]
      )
      deposit.invoice!
    end
  end

  private

  # Save beneficiary for future withdraws
  def save_beneficiary(deposit, address)
    if address.blank?
      Rails.logger.warn("Deposit #{deposit.id} has no address to save beneficiaries")
      return
    end
    Rails.logger.info("Save #{address} as beneficiary for #{deposit.account.id}")

    beneficiary_name = [ENV.fetch('BENEFICIARY_PREFIX', 'bitzlato'), address].compact.join(':')

    blockchain.currencies.each do |currency|
      deposit.account.member.beneficiaries
             .create_with(data: { address: address }, state: :active)
             .find_or_create_by!(
               name: beneficiary_name,
               currency: currency
             )
    end
  rescue StandardError => e
    report_exception e, true, { deposit_id: deposit.id, address: address }
  end

  def build_client
    Bitzlato::Wallet.new
  end
end
# rubocop:enable Lint/UnusedMethodArgument
