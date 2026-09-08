# frozen_string_literal: true

module Billing
  class MerchantProfile < ApplicationRecord
    belongs_to :user, class_name: "::User", optional: true
    has_many :plans, dependent: :restrict_with_error
    has_many :payout_addresses, dependent: :destroy
    has_one_attached :image
    attr_accessor :image_upload
    validate :validate_image_upload
    before_save :assign_image_upload
    validates :public_id, presence: true, uniqueness: true, format: { with: /\A[a-z0-9][a-z0-9_-]{2,63}\z/ }
    validates :display_name, presence: true, length: { maximum: 100 }
    validates :introduction, length: { maximum: 5000 }

    def to_param
      public_id
    end

    private
      def validate_image_upload
        return if image_upload.blank?

        ::AvatarImagePolicy.validate!(::AvatarUpload.coerce(image_upload))
      rescue ::AvatarUpload::Error
        errors.add(:image_upload, :undecodable)
      rescue ::AvatarImagePolicy::ValidationError => error
        errors.add(:image_upload, error.code, max_size: ::AvatarImagePolicy::MAX_SIZE_LABEL,
          max_dimension: ::AvatarImagePolicy::MAX_DIMENSION)
      end

      def assign_image_upload
        return if image_upload.blank?

        self.image = image_upload
        self.image_upload = nil
      end
  end
end
