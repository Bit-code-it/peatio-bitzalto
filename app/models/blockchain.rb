# encoding: UTF-8
# frozen_string_literal: true

# Rename to Gateway
#
class Blockchain < ApplicationRecord
  include GatewayConcern
  include Vault::EncryptedModel

  vault_lazy_decrypt!
  vault_attribute :server

  has_many :wallets
  has_many :whitelisted_smart_contracts
  has_many :withdraws
  has_many :currencies
  has_many :payment_addresses
  has_many :transactions, through: :currencies
  has_many :deposits, through: :currencies

  validates :key, :name, presence: true, uniqueness: true
  validates :status, inclusion: { in: %w[active disabled] }
  validates :height,
            :min_confirmations,
            numericality: { greater_than_or_equal_to: 1, only_integer: true }
  validates :server, url: { allow_blank: true }
  before_create { self.key = self.key.strip.downcase }

  scope :active, -> { where(status: :active) }

  def explorer=(hash)
    write_attribute(:explorer_address, hash.fetch('address'))
    write_attribute(:explorer_transaction, hash.fetch('transaction'))
  end

  def supports_cash_addr_format?
    implements? :cash_addr
  end

  def native_currency
    currencies.find { |c| c.parent_id.nil? } || raise("No native currency for wallet id #{id}")
  end

  def status
    super&.inquiry
  end

  def service
    @blockchain_service ||= BlockchainService.new(self)
  end

  def find_money_currency(contract_address=nil)
    currencies.map(&:money_currency)
      .find { |mc| mc.contract_address.presence == contract_address.presence } ||
      raise("No found currency for '#{contract_address || :empty}' contract address in blockchain #{self}")
  end

  def wallets_addresses
    @wallets_addresses ||= wallets.where.not(address: nil).pluck(:address)
  end

  def deposit_addresses
    @deposit_addresses ||= payment_addresses.where.not(address: nil).pluck(:address)
  end

  def follow_addresses
    @follow_addresses ||= wallets_addresses + deposit_addresses
  end

  def contract_addresses
    @contract_addresses ||= currencies.tokens.map(&:contract_address)
  end

  def active?
    status.active?
  end

  # The latest block which blockchain worker has processed
  def processed_height
    height + min_confirmations
  end
end
