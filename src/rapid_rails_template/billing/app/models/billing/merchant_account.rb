# frozen_string_literal: true

module Billing
  class MerchantAccount < ApplicationRecord
    has_many :plans, dependent: :restrict_with_error
    has_many :payout_addresses, dependent: :restrict_with_error
    has_many :memberships, class_name: 'Billing::MerchantMembership', dependent: :restrict_with_error
    has_many :users, through: :memberships
    has_many :invitations, class_name: 'Billing::MerchantInvitation', dependent: :restrict_with_error
    has_many :audit_entries, dependent: :restrict_with_error
    has_one_attached :image
    attr_accessor :image_upload, :creator

    validates :status, inclusion: { in: %w(active closing closed) }
    validates :fee_basis_points, numericality: { only_integer: true, in: 0..10_000 }, allow_nil: true
    around_save :save_account
    before_destroy { throw :abort }
    validate :validate_image_upload
    before_save :assign_image_upload
    validates :public_id, presence: true, uniqueness: true, format: { with: /\A[a-z0-9][a-z0-9_-]{2,63}\z/ }
    validates :display_name, presence: true, length: { maximum: 100 }
    validates :introduction, length: { maximum: 5000 }

    def to_param
      public_id
    end

    def effective_fee_basis_points(setting: Setting.current)
      fee_basis_points.nil? ? setting.fee_basis_points : fee_basis_points
    end

    def outstanding?(at: Time.current)
      contracts = Subscription.where(plan_id: plans.select(:id))
      contracts.exists?(ended_at: nil) || contracts.exists?(['paid_until > ?', at]) ||
        Transaction.exists?(subscription_id: contracts.select(:id), finalized_at: nil)
    end

    private

    def save_account
      MerchantAccess.synchronize do
        creating = new_record?
        if creating
          raise MerchantAccess::Denied if Current.actor && Current.actor != creator
          raise MerchantAccess::Denied unless MerchantAccess.eligible?(creator)
          raise Error, 'new merchant must be active' unless status == 'active'
          if fee_basis_points.present? && Current.actor && !MerchantAccess.app_admin?(Current.actor)
            raise MerchantAccess::Denied
          end
        elsif Current.actor
          permission = will_save_change_to_status? ? :manage : :edit
          if will_save_change_to_fee_basis_points?
            raise MerchantAccess::Denied unless MerchantAccess.app_admin?(Current.actor)
          end
          if (changes.keys - %w(fee_basis_points updated_at)).any? || image_upload.present? || attachment_changes.any?
            MerchantAccess.authorize!(Current.actor, self, permission)
          end
        end
        if !creating && will_save_change_to_status? &&
           [['active', 'closing'], ['closing', 'closed']].exclude?([self.class.find(id).status, status])
          errors.add(:status, :invalid)
          raise ActiveRecord::RecordInvalid, self
        end
        raise Error, 'merchant still has obligations' if status == 'closed' && outstanding?

        image_changed = image_upload.present? || attachment_changes.key?('image')
        previous_image = ActiveStorage::Attachment.find_by(record: self, name: 'image')&.blob&.filename&.to_s if image_changed && persisted?
        yield
        memberships.create!(user: creator, role: 'admin') if creating
        changes = saved_changes.slice('public_id', 'display_name', 'introduction', 'status', 'fee_basis_points')
        changes['image'] = [previous_image, T.must(image.blob).filename.to_s] if image_changed && image.attached?
        unless changes.empty?
          AuditEntry.record!(merchant: self, target: self, action: 'merchant_account.changed',
                             before_values: changes.transform_values(&:first), after_values: changes.transform_values(&:last))
        end
      end
    end

    def validate_image_upload
      return if image_upload.blank?

      ::AvatarImagePolicy.validate!(::AvatarUpload.coerce(image_upload))
    rescue ::AvatarUpload::Error
      errors.add(:image_upload, :undecodable)
    rescue ::AvatarImagePolicy::ValidationError => e
      errors.add(:image_upload, e.code, max_size: ::AvatarImagePolicy::MAX_SIZE_LABEL,
                                        max_dimension: ::AvatarImagePolicy::MAX_DIMENSION)
    end

    def assign_image_upload
      return if image_upload.blank?

      self.image = image_upload
      self.image_upload = nil
    end
  end
end
