# frozen_string_literal: true

module Billing
  module Invitations
    def self.create!(merchant:, actor:, screen_name:, role:, now: Time.current)
      MerchantAccess.synchronize(merchant) do
        MerchantAccess.authorize!(actor, merchant, :manage)
        recipient = T.must(::Profile.find_by!(screen_name: screen_name).user)
        raise MerchantAccess::Denied unless MerchantAccess.eligible?(recipient)
        raise Error, 'already a member' if merchant.memberships.exists?(user_id: recipient.id)

        Current.set(actor: actor) do
          merchant.invitations.where(recipient: recipient, status: 'pending').where(expires_at: ..now).find_each do |invitation|
            resolve!(invitation, 'expired', now)
          end
          invitation = merchant.invitations.create!(recipient: recipient, inviter: actor, role: role, expires_at: now + 7.days)
          audit!(invitation, 'created')
          Event.record!("invitation:#{invitation.id}", user: recipient, message: 'merchant_invitation', path: '/merchant/billing/invitations')
          invitation
        end
      end
    end

    def self.respond!(invitation:, actor:, response:, now: Time.current)
      MerchantAccess.synchronize(invitation.merchant_account) do
        invitation.lock!
        raise MerchantAccess::Denied unless actor && invitation.recipient_id == actor.id
        raise Error, 'invitation is not pending' unless invitation.status == 'pending'
        raise ArgumentError, 'invalid invitation response' unless %w(accepted rejected).include?(response)

        Current.set(actor: actor) do
          if response == 'accepted'
            raise Error, 'invitation expired' unless now < invitation.expires_at

            MerchantAccess.authorize!(invitation.inviter, invitation.merchant_account, :manage)
            raise MerchantAccess::Denied unless MerchantAccess.eligible?(actor)

            # Acceptance is authorized by the still-valid inviter, and audited as the recipient.
            Current.set(authorization_actor: invitation.inviter) do
              invitation.merchant_account.memberships.create!(user: actor, role: invitation.role)
            end
          end
          resolve!(invitation, response, now)
        end
      end
    end

    def self.revoke!(invitation:, actor:, now: Time.current)
      MerchantAccess.synchronize(invitation.merchant_account) do
        MerchantAccess.authorize!(actor, invitation.merchant_account, :manage)
        invitation.lock!
        raise Error, 'invitation is not pending' unless invitation.status == 'pending'

        Current.set(actor: actor) { resolve!(invitation, 'revoked', now) }
      end
    end

    def self.resolve!(invitation, status, now)
      invitation.update!(status: status, resolved_at: now)
      audit!(invitation, status)
    end

    def self.audit!(invitation, action)
      AuditEntry.record!(merchant: invitation.merchant_account, target: invitation, action: "invitation.#{action}",
                         before_values: invitation.saved_changes.slice('status').transform_values(&:first),
                         after_values: invitation.attributes.slice('recipient_id', 'inviter_id', 'role', 'status', 'expires_at').merge(
                           'recipient_name' => invitation.recipient&.profile&.display_name,
                           'inviter_name' => invitation.inviter&.profile&.display_name
                         ))
    end
    private_class_method :resolve!, :audit!
  end
end
