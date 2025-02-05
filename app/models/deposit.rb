# frozen_string_literal: true

class Deposit < ApplicationRecord
  # TODO: rename dispatched to completed
  #
  serialize :error, JSON unless Rails.configuration.database_support_json
  serialize :from_addresses, Array
  serialize :data, JSON unless Rails.configuration.database_support_json

  include AASM
  include TIDIdentifiable
  include FeeChargeable

  extend Enumerize

  belongs_to :currency, optional: false, touch: false
  belongs_to :member, optional: false
  belongs_to :blockchain, touch: false
  has_many :deposit_spreads

  acts_as_eventable prefix: 'deposit', on: %i[create update]

  enumerize :transfer_type, in: DEPOSIT_TRANSFER_TYPES

  scope :recent, -> { order(id: :desc) }

  before_validation { self.completed_at ||= Time.current if completed? }
  before_validation { self.transfer_type ||= currency.coin? ? 'crypto' : 'fiat' }
  after_commit :trigger_private_event

  validates :tid, presence: true, uniqueness: { case_sensitive: false }
  validates :aasm_state, :type, presence: true
  validates :completed_at, presence: { if: :completed? }
  validates :block_number, allow_blank: true, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :amount, numericality: { greater_than: 0.0 }

  delegate :key, to: :blockchain, prefix: true

  aasm whiny_transitions: true, requires_lock: true do
    state :submitted, initial: true
    state :invoiced
    state :canceled
    state :rejected
    state :accepted
    state :aml_check
    state :skipped
    state :dispatched
    state :errored
    state :refunding
    state :rolledback
    event(:cancel) { transitions from: %i[submitted invoiced], to: :canceled }
    event(:reject) { transitions from: %i[submitted invoiced], to: :rejected }
    event :accept do
      transitions from: %i[submitted invoiced skipped], to: :accepted
      after do
        if currency.coin? && (Peatio::App.config.deposit_funds_locked ||
                              Peatio::App.config.manual_deposit_approval)
          account.plus_locked_funds(amount)
          update!(is_locked: true)
        else
          account.plus_funds(amount)
        end
        record_submit_operations!
      end
    end
    event :skip do
      transitions from: :submitted, to: :skipped
    end

    event :invoice do
      transitions from: :submitted, to: :invoiced
      after do
        update(invoice_expires_at: Time.now + ENV.fetch('INVOICE_EXPIRES_HOURS', 24).hours)
      end
    end

    event :aml_check do
      transitions from: :accepted, to: :aml_check
    end

    event :dispatch do
      transitions from: %i[errored accepted aml_check], to: :dispatched
      after do
        if Peatio::App.config.deposit_funds_locked
          account.unlock_funds(amount)
          update!(is_locked: false)
          record_complete_operations!
        end
      end
    end

    event :refund do
      transitions from: %i[skipped], to: :refunding do
        guard { currency.coin? }
      end
    end

    event :rollback do
      transitions from: %i[dispatched], to: :rolledback
      after do
        account.unlock_funds(account.locked)
        account.sub_funds! amount
        update!(:is_locked, false)
        # TODO: rollback operations
      end
    end
  end

  delegate :gateway, to: :blockchain

  def transfer_links
    # TODO: rename data['links'] to transfer_links
    # TODO rename data['expires_at'] to expires_at
    # TODO Use txid instead of invoice_id
    data&.fetch 'links', []
  end

  def deposit_errors
    Array(error).freeze
  end

  def add_error(e)
    error_hash = e.is_a?(StandardError) ? { class: e.class.to_s, message: e.message } : { message: e }
    update!(error: deposit_errors + [error_hash])
  end

  def account
    member&.get_account(currency)
  end

  def uid
    member&.uid
  end

  def uid=(uid)
    self.member = Member.find_by_uid(uid)
  end

  def payment_address
    member.payment_address blockchain
  end

  def as_json_for_event_api
    { tid: tid,
      user: { uid: member.uid, email: member.email },
      uid: member.uid,
      currency: currency_id,
      amount: amount.to_s('F'),
      state: aasm_state,
      blockchain_state: blockchain.status,
      created_at: created_at.iso8601,
      updated_at: updated_at.iso8601,
      completed_at: completed_at&.iso8601,
      blockchain_address: address,
      blockchain_txid: txid }
  end

  def completed?
    !submitted?
  end

  def process!
    # только для совместимости
    # TODO удалить
  end

  def for_notify
    API::V2::Entities::Deposit.represent(self).as_json
  end

  def trigger_private_event
    ::AMQP::Queue.enqueue_event('private', member&.uid, 'deposit', for_notify)
  end

  private

  # Creates dependant operations for deposit.
  def record_submit_operations!
    transaction do
      # Credit main fiat/crypto Asset account.
      Operations::Asset.credit!(
        amount: amount + fee,
        currency: currency,
        reference: self
      )

      # Credit main fiat/crypto Revenue account.
      Operations::Revenue.credit!(
        amount: fee,
        currency: currency,
        reference: self,
        member_id: member_id
      )

      locked_kind_check = currency.coin? && (Peatio::App.config.deposit_funds_locked || Peatio::App.config.manual_deposit_approval)
      kind = locked_kind_check ? :locked : :main
      # Credit locked fiat/crypto Liability account.
      Operations::Liability.credit!(
        amount: amount,
        currency: currency,
        reference: self,
        member_id: member_id,
        kind: kind
      )
    end
  end

  # Creates dependant operations for complete deposit.
  def record_complete_operations!
    transaction do
      Operations::Liability.transfer!(
        amount: amount,
        currency: currency,
        reference: self,
        from_kind: :locked,
        to_kind: :main,
        member_id: member_id
      )
    end
  end

  def blockchain_currency
    @blockchain_currency ||= BlockchainCurrency.find_by!(blockchain: blockchain, currency: currency)
  end
end
