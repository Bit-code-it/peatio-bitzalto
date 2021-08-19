class Transaction < ApplicationRecord
  # == Constants ============================================================

  PENDING_STATUS = 'pending'
  SUCCESS_STATUS = 'succeed'
  FAIL_STATUS = 'failed'
  STATUSES = [PENDING_STATUS, SUCCESS_STATUS, FAIL_STATUS].freeze

  # == Attributes ===========================================================

  # == Extensions ===========================================================

  serialize :data, JSON unless Rails.configuration.database_support_json

  # == Relationships ========================================================

  belongs_to :reference, polymorphic: true
  belongs_to :currency
  has_one :blockchain, through: :currency

  # == Validations ==========================================================

  validates :currency, :amount, :from_address, :to_address, :status, presence: true

  validates :status, inclusion: { in: STATUSES }

  # == Scopes ===============================================================

  # == Callbacks ============================================================

  after_initialize :initialize_defaults, if: :new_record?

  # TODO: record expenses for succeed transactions

  def self.create_from_blockchain_transaction!(tx, extra = {})
    create!(
      {
        from_address: tx.from_address,
        to_address: tx.to_address,
        currency_id: tx.currency_id,
        txid: tx.txid,
        block_number: tx.block_number,
        amount: tx.amount,
        status: tx.status,
        txout: tx.txout,
        options: tx.options,
      }.deep_merge(extra)
    )
  end

  def initialize_defaults
    self.status = :pending if status.blank?
  end

  def transaction_url
    blockchain.explore_transaction_url txid if blockchain
  end

  # TODO Validate txid by blockchain
end
