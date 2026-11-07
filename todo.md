While reading app/services/payments/process_stripe_webhook.rb I noticed what look like bugs. I didn't change anything:

- refund.updated breaks on a failed refund: it calls process_refund_failed!(refund), but that method takes no arguments, so it would raise an error.
- Cancelled payouts: process_withdrawal_cancelled! sets the status to :cancelled, but the rest of the code checks canceled?. One of the two spellings is wrong.
- Missing user in audit logs: the withdrawal handlers pass user: @user, which is never set, so those entries are saved with no user.
