# frozen_string_literal: true

require_relative "../billing_test_helper"

class BillingMerchantTest < BillingTest
  def setup
    super
    @editor = User.create!(name: "Editor")
    @viewer = User.create!(name: "Viewer")
    @admin = User.create!(name: "App admin")
    UserRole.create!(user_id: @admin.id, role: "admin")
    @merchant.memberships.create!(user: @editor, role: "editor")
    @merchant.memberships.create!(user: @viewer, role: "viewer")
  end

  def test_role_boundaries_and_app_admin_without_membership
    { @user => [true, true, true], @editor => [true, true, false], @viewer => [true, false, false], @admin => [false, false, false] }.each do |user, expected|
      assert_equal expected, %i[view edit manage].map { |permission| Billing::MerchantAccess.allowed?(user, @merchant, permission) }
    end
    Billing::Current.set(actor: @viewer) do
      assert_raises(Billing::MerchantAccess::Denied) { @plan.update!(name: "Unauthorized") }
    end
    assert_equal "30 days", @plan.reload.name
    Billing::Current.set(actor: @editor) { @plan.update!(name: "Edited") }
    assert_equal "Edited", @plan.reload.name
  end

  def test_multiple_merchants_and_unique_memberships
    other = Billing::MerchantAccount.create!(creator: @user, public_id: "second", display_name: "Second")
    assert_equal [@merchant.id, other.id], @user.merchant_accounts.order(:id).pluck(:id)
    assert_raises(ActiveRecord::RecordInvalid) { @merchant.memberships.create!(user: @viewer, role: "admin") }
    assert_raises(ActiveRecord::RecordInvalid) { @plan.update!(merchant_account: other) }
    membership = @merchant.memberships.find_by!(user: @viewer)
    assert_raises(ActiveRecord::RecordInvalid) { membership.update!(merchant_account: other) }
    assert_raises(ActiveRecord::RecordInvalid) { membership.reload.update!(user: @admin) }
    assert_equal @viewer.id, membership.reload.user_id
    assert_equal @merchant.id, membership.merchant_account_id
  end

  def test_subscription_creation_rechecks_payment_setting_and_merchant_closure
    @setting.update!(payments_enabled: false)
    assert_raises(Billing::ConfigurationError) { subscription }
    @setting.update!(payments_enabled: true)
    Billing::MerchantClosure.start!(merchant: @merchant, actor: @user, now: @now)
    assert_raises(Billing::ConfigurationError) { subscription }
    assert_empty @plan.subscriptions
  end

  def test_merchant_creation_cannot_assign_another_user_as_creator
    Billing::Current.set(actor: @viewer) do
      assert_raises(Billing::MerchantAccess::Denied) do
        Billing::MerchantAccount.create!(creator: @admin, public_id: "forged", display_name: "Forged")
      end
    end
    refute Billing::MerchantAccount.exists?(public_id: "forged")
  end

  def test_last_admin_cannot_leave_or_be_demoted_and_peer_admin_can_replace_creator
    first = @merchant.memberships.find_by!(user: @user)
    assert_raises(ActiveRecord::RecordInvalid) { first.destroy! }
    assert_raises(ActiveRecord::RecordInvalid) { first.update!(role: "viewer") }
    assert_equal "admin", first.reload.role
    Billing::Current.set(actor: @user) { @merchant.memberships.find_by!(user: @editor).update!(role: "admin") }
    Billing::Current.set(actor: @editor) { first.destroy! }
    assert_equal @editor.id, @merchant.memberships.where(role: "admin").sole.user_id
  end

  def test_admin_only_setting_and_role_revocation_preserve_an_eligible_admin
    assert_raises(ActiveRecord::RecordInvalid) { @setting.update!(admin_only: true) }
    refute @setting.reload.admin_only?
    assignment = UserRole.create!(user_id: @user.id, role: "admin")
    @setting.update!(admin_only: true)
    assert Billing::MerchantAccess.allowed?(@user, @merchant)
    refute Billing::MerchantAccess.allowed?(@editor, @merchant)
    assert_raises(ActiveRecord::RecordInvalid) { assignment.destroy! }
    assert UserRole.exists?(assignment.id)
    @merchant.memberships.create!(user: @admin, role: "admin")
    assignment.destroy!
    refute Billing::MerchantAccess.allowed?(@user, @merchant)
    assert_equal 4, @merchant.memberships.count
  end

  def test_invitation_binds_user_id_and_accepts_once_after_username_change
    target = User.create!(name: "Invited")
    invitation = invite(target)
    target.profile.update!(screen_name: "renamed")
    Billing::Invitations.respond!(invitation: invitation, actor: target, response: "accepted", now: @now + 1.day)
    assert_equal "editor", @merchant.memberships.find_by!(user: target).role
    assert_equal target.id, @merchant.audit_entries.where(action: "membership.changed").last.actor_id
    assert_raises(Billing::Error) { Billing::Invitations.respond!(invitation: invitation, actor: target, response: "accepted", now: @now + 1.day) }
  end

  def test_expired_revoked_duplicate_and_wrong_recipient_invitations
    target = User.create!(name: "Invited")
    invitation = invite(target)
    assert_raises(ActiveRecord::RecordNotUnique) { invite(target) }
    assert_raises(Billing::MerchantAccess::Denied) { Billing::Invitations.respond!(invitation: invitation, actor: @viewer, response: "accepted", now: @now) }
    assert_raises(Billing::Error) { Billing::Invitations.respond!(invitation: invitation, actor: target, response: "accepted", now: @now + 7.days) }
    Billing::Invitations.revoke!(invitation: invitation, actor: @user, now: @now)
    assert_raises(Billing::Error) { Billing::Invitations.respond!(invitation: invitation, actor: target, response: "accepted", now: @now) }
    refute @merchant.memberships.exists?(user: target)
  end

  def test_acceptance_rechecks_inviter_role_target_eligibility_and_closed_state
    target = User.create!(name: "Invited")
    invitation = invite(target)
    @merchant.memberships.find_by!(user: @editor).update!(role: "admin")
    @merchant.memberships.find_by!(user: @user).update!(role: "viewer")
    assert_raises(Billing::MerchantAccess::Denied) { Billing::Invitations.respond!(invitation: invitation, actor: target, response: "accepted", now: @now) }
    @merchant.memberships.find_by!(user: @user).update!(role: "admin")
    UserRole.create!(user_id: @user.id, role: "admin")
    @setting.update!(admin_only: true)
    assert_raises(Billing::MerchantAccess::Denied) { Billing::Invitations.respond!(invitation: invitation, actor: target, response: "accepted", now: @now) }
    @setting.update!(admin_only: false)
    Billing::MerchantClosure.start!(merchant: @merchant, actor: @user, now: @now)
    Billing::MerchantClosure.complete!(@merchant, now: @now)
    assert_raises(Billing::MerchantAccess::Denied) { Billing::Invitations.respond!(invitation: invitation, actor: target, response: "accepted", now: @now) }
  end

  def test_fee_override_zero_hundred_and_same_destination_are_snapshotted
    contract = subscription
    [nil, 0, 10_000, 250].each_with_index do |rate, index|
      @merchant.update!(fee_basis_points: rate)
      @merchant.payout_addresses.sole.update!(address: @chain.treasury_address)
      contract.update!(paid_until: index.zero? ? nil : @now + index * 30.days)
      charge = Billing::ChargeBuilder.call(contract, now: @now + index * 30.days)
      effective = rate.nil? ? 100 : rate
      assert_equal Billing::Amount.split(contract.amount_units, effective), [charge.operator_units, charge.merchant_units]
      assert_equal effective, charge.fee_basis_points
      assert_equal charge.operator_address, charge.merchant_address
      charge.update!(status: "settled")
    end
    assert_equal 100, contract.charges.order(:id).first.fee_basis_points
  end

  def test_fee_authority_does_not_allow_app_admin_to_edit_public_profile
    Billing::Current.set(actor: @admin) do
      @merchant.update!(fee_basis_points: 0)
      assert_raises(Billing::MerchantAccess::Denied) { @merchant.update!(fee_basis_points: 100, display_name: "Unauthorized") }
    end
    assert_equal "Merchant", @merchant.reload.display_name
    Billing::Current.set(actor: @user) do
      assert_raises(Billing::MerchantAccess::Denied) { @merchant.update!(fee_basis_points: 500) }
    end
  end

  def test_closure_preserves_paid_access_blocks_billing_and_waits_for_obligations
    contract = subscription(paid_from: @now, paid_until: @now + 30.days, status: "active")
    Billing::MerchantClosure.start!(merchant: @merchant, actor: @user, now: @now)
    assert_equal "closing", @merchant.reload.status
    assert contract.reload.cancel_requested_at
    assert contract.usable?(at: @now + 29.days)
    assert_nil Billing::ChargeBuilder.call(contract, now: @now + 30.days)
    Billing::MerchantClosure.complete!(@merchant, now: @now)
    assert_equal "closing", @merchant.reload.status
    contract.update!(ended_at: @now + 30.days, revoked_at: @now, status: "ended", paid_until: @now)
    Billing::MerchantClosure.complete!(@merchant, now: Time.current)
    assert_equal "closed", @merchant.reload.status
    assert_raises(ActiveRecord::RecordInvalid) { @merchant.update!(status: "active") }
    assert Billing::MerchantAccess.allowed?(@viewer, @merchant)
    refute Billing::MerchantAccess.allowed?(@user, @merchant, :manage)
  end

  def test_audit_is_separate_from_notifications_and_survives_user_deletion
    Billing::Current.set(actor: @editor) { @plan.update!(name: "New title") }
    entry = @merchant.audit_entries.where(target_type: "Billing::Plan").last
    assert_equal "30 days", entry.before_values.fetch("name")
    assert_equal "New title", entry.after_values.fetch("name")
    assert_equal 0, Billing::Event.count
    @merchant.memberships.find_by!(user: @editor).destroy!
    @editor.destroy!
    assert_nil entry.reload.actor_id
    assert_equal "Editor", entry.actor_name
    removal = @merchant.audit_entries.where(action: "membership.removed").last
    assert_equal "Editor", removal.before_values.fetch("user_name")
    assert_equal @editor.id, removal.before_values.fetch("user_id")
    assert_raises(ActiveRecord::ReadOnlyRecord) { entry.update!(actor_name: "Changed") }
  end

  def test_actionable_notifications_target_all_eligible_members_and_deduplicate
    2.times { Billing::Event.merchant!(@merchant, "charge:42:held", "collection_held") }
    assert_equal [@user.id, @editor.id, @viewer.id], Billing::Event.order(:user_id).pluck(:user_id)
    UserRole.create!(user_id: @user.id, role: "admin")
    @setting.update!(admin_only: true)
    Billing::Event.merchant!(@merchant, "charge:43:held", "collection_held")
    assert_equal 4, Billing::Event.count
    assert_equal @user.id, Billing::Event.last.user_id
  end

  private
    def invite(target)
      Billing::Invitations.create!(merchant: @merchant, actor: @user, screen_name: target.profile.screen_name, role: "editor", now: @now)
    end
end
